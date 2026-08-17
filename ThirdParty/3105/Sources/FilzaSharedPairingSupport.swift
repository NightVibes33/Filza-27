import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Filza-wide pairing consumer for 3105.
///
/// The pairing file and live LocalDevVPN/RSD or lockdown transport remain owned
/// by ByeTunes' existing DeviceManager singleton. 3105 only borrows that live
/// transport to ask SpringBoardServices for rendered app icons. App discovery
/// itself stays on 3105's existing broader ContainerStore/MCM/LaunchServices
/// pipeline and never depends on pairing.
@MainActor
enum FilzaSharedPairingSupport {
    private static let enhancedIconCache = NSCache<NSString, UIImage>()

    // SpringBoardServices is substantially faster when a small number of
    // persistent service clients are reused instead of reconnecting once per
    // app row. Each Swift worker maps deterministically to one native client
    // slot, allowing limited concurrency without flooding the paired tunnel.
    private static let iconWorkers: [DispatchQueue] = (0..<3).map { index in
        DispatchQueue(
            label: "com.nightvibes33.filza27.3105.springboard-icons.\(index)",
            qos: .userInitiated
        )
    }
    private static let fallbackQueue = DispatchQueue(
        label: "com.nightvibes33.filza27.3105.launchservices-icons",
        qos: .utility,
        attributes: .concurrent
    )

    // Multiple SwiftUI rows for the same app can appear while the catalog is
    // progressively merged. Coalesce those duplicate SpringBoard requests.
    private static var iconWaiters: [String: [CheckedContinuation<UIImage?, Never>]] = [:]

    // A nil result is not permanently cached: service/transient failures get
    // another chance shortly afterwards while obvious repeated misses are
    // briefly throttled so scrolling does not hammer SpringBoardServices.
    private static var iconRetryAfter: [String: Date] = [:]

    private static var connectionInFlight = false
    private static var connectionWaiters: [CheckedContinuation<Bool, Never>] = []
    private static var retryConnectionAfter = Date.distantPast

    static var hasActiveTransport: Bool {
        let manager = DeviceManager.shared
        if let _ = manager.rpAdapter, let _ = manager.rpHandshake {
            return true
        }
        return manager.provider != nil
    }

    static var isEnhancedIconServiceReady: Bool {
        DeviceManager.shared.heartbeatReady && hasActiveTransport
    }

    /// Fetch only the higher-quality SpringBoardServices icon.
    ///
    /// Callers are expected to show their existing 3105/LaunchServices icon
    /// immediately and then replace it if this async upgrade succeeds.
    static func enhancedIcon(for bundleID: String) async -> UIImage? {
        guard !bundleID.isEmpty else { return nil }

        if let cached = enhancedIconCache.object(forKey: bundleID as NSString) {
            return cached
        }

        if let retryDate = iconRetryAfter[bundleID], Date() < retryDate {
            return nil
        }

        if iconWaiters[bundleID] != nil {
            return await withCheckedContinuation { continuation in
                iconWaiters[bundleID, default: []].append(continuation)
            }
        }

        iconWaiters[bundleID] = []

        let icon: UIImage?
        if await ensureSharedTransport() {
            icon = await fetchSpringBoardIcon(bundleID: bundleID)
        } else {
            icon = nil
        }

        if let icon {
            enhancedIconCache.setObject(icon, forKey: bundleID as NSString)
            iconRetryAfter.removeValue(forKey: bundleID)
        } else {
            // Do not permanently negative-cache. A short throttle avoids one
            // failed internal/system entry repeatedly consuming a worker.
            iconRetryAfter[bundleID] = Date().addingTimeInterval(8)
        }

        let waiters = iconWaiters.removeValue(forKey: bundleID) ?? []
        waiters.forEach { $0.resume(returning: icon) }
        return icon
    }

    /// Backwards-compatible best-icon resolver for other 3105 call sites.
    /// The Apps Manager itself now paints LaunchServices immediately and uses
    /// enhancedIcon(for:) only as an asynchronous visual upgrade.
    static func resolvedIcon(for bundleID: String) async -> UIImage? {
        if let enhanced = await enhancedIcon(for: bundleID) {
            return enhanced
        }
        return await runOnFallbackQueue {
            iconForBundleID(bundleID)
        }
    }

    static func clearEnhancedIconCache() {
        enhancedIconCache.removeAllObjects()
        iconRetryAfter.removeAll()
    }

    /// Clear icon state and allow an immediate transport retry. The pairing
    /// file itself is deliberately not removed here. Native persistent service
    /// clients detect changed transport handles and rebuild themselves.
    static func resetAfterPairingChange() {
        enhancedIconCache.removeAllObjects()
        iconRetryAfter.removeAll()
        retryConnectionAfter = .distantPast
    }

    private static func ensureSharedTransport() async -> Bool {
        let manager = DeviceManager.shared

        // The hot path should not re-read pairing state for every visible row.
        if manager.heartbeatReady && hasActiveTransport {
            return true
        }

        manager.refreshExpectedPairingFileState()
        guard manager.hasValidExpectedPairingFile else {
            return false
        }

        // ByeTunes may already be establishing the shared connection. Do not
        // race it with a second tunnel; wait briefly for its handles instead.
        if manager.connectionStatus == "Connecting..." {
            return await waitForSharedTransport(timeout: 6.0)
        }

        if connectionInFlight {
            return await withCheckedContinuation { continuation in
                connectionWaiters.append(continuation)
            }
        }

        guard Date() >= retryConnectionAfter else {
            return false
        }

        connectionInFlight = true
        return await withCheckedContinuation { continuation in
            manager.startHeartbeat(forceReconnect: false) { success in
                Task { @MainActor in
                    let ready = success
                        && DeviceManager.shared.heartbeatReady
                        && FilzaSharedPairingSupport.hasActiveTransport

                    FilzaSharedPairingSupport.connectionInFlight = false
                    if ready {
                        FilzaSharedPairingSupport.retryConnectionAfter = .distantPast
                    } else {
                        // Avoid starting one expensive tunnel attempt per row
                        // when LocalDevVPN is unavailable.
                        FilzaSharedPairingSupport.retryConnectionAfter = Date().addingTimeInterval(10)
                    }

                    continuation.resume(returning: ready)
                    let waiters = FilzaSharedPairingSupport.connectionWaiters
                    FilzaSharedPairingSupport.connectionWaiters.removeAll()
                    waiters.forEach { $0.resume(returning: ready) }
                }
            }
        }
    }

    private static func waitForSharedTransport(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DeviceManager.shared.heartbeatReady && hasActiveTransport {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        retryConnectionAfter = Date().addingTimeInterval(5)
        return false
    }

    private static func fetchSpringBoardIcon(bundleID: String) async -> UIImage? {
        let manager = DeviceManager.shared

        if let adapter = manager.rpAdapter,
           let handshake = manager.rpHandshake {
            return await runOnIconWorker(bundleID: bundleID) {
                filzaSpringBoardIconForBundleIDRSD(adapter, handshake, bundleID)
            }
        }

        if let provider = manager.provider {
            return await runOnIconWorker(bundleID: bundleID) {
                filzaSpringBoardIconForBundleIDProvider(provider, bundleID)
            }
        }

        return nil
    }

    private static func workerIndex(for bundleID: String) -> Int {
        var hash = 5381
        for byte in bundleID.utf8 {
            hash = (hash &* 33) &+ Int(byte)
        }
        let remainder = hash % iconWorkers.count
        return remainder >= 0 ? remainder : -remainder
    }

    private static func runOnIconWorker(
        bundleID: String,
        _ work: @escaping () -> UIImage?
    ) async -> UIImage? {
        let queue = iconWorkers[workerIndex(for: bundleID)]
        return await withCheckedContinuation { continuation in
            queue.async {
                autoreleasepool {
                    continuation.resume(returning: work())
                }
            }
        }
    }

    private static func runOnFallbackQueue(_ work: @escaping () -> UIImage?) async -> UIImage? {
        await withCheckedContinuation { continuation in
            fallbackQueue.async {
                autoreleasepool {
                    continuation.resume(returning: work())
                }
            }
        }
    }
}

/// Shared pairing controls shown inside 3105 -> Settings.
/// Selecting a file here updates the exact same DeviceManager instance and
/// canonical pairing path used by embedded ByeTunes.
struct Filza3105PairingSettingsSection: View {
    @ObservedObject private var manager = DeviceManager.shared
    @State private var showingPairingImporter = false
    @State private var showingMessage = false
    @State private var message = ""

    private var connected: Bool {
        manager.heartbeatReady && FilzaSharedPairingSupport.hasActiveTransport
    }

    var body: some View {
        Section {
            LabeledContent("Shared Pairing") {
                Label(
                    manager.hasValidExpectedPairingFile ? "Available" : "Not Configured",
                    systemImage: manager.hasValidExpectedPairingFile ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(manager.hasValidExpectedPairingFile ? Color.green : Color.secondary)
            }

            LabeledContent("Pairing Type", value: manager.expectedPairingFileTitle)

            LabeledContent("Device Tunnel") {
                Label(
                    connected ? "Connected" : manager.connectionStatus,
                    systemImage: connected ? "link.circle.fill" : "link.circle"
                )
                .foregroundStyle(connected ? Color.green : Color.secondary)
            }

            LabeledContent("Enhanced App Icons") {
                Text(connected ? "SpringBoardServices" : "LaunchServices fallback")
                    .foregroundStyle(connected ? Color.green : Color.secondary)
            }

            if connected {
                Button {
                    FilzaSharedPairingSupport.clearEnhancedIconCache()
                    message = "Enhanced icon cache cleared. Icons will be requested from SpringBoard again as app rows appear."
                    showingMessage = true
                } label: {
                    Label("Refresh Enhanced Icons", systemImage: "arrow.clockwise")
                }
            } else {
                if manager.hasValidExpectedPairingFile {
                    Button {
                        FilzaSharedPairingSupport.resetAfterPairingChange()
                        manager.startHeartbeat(forceReconnect: true)
                    } label: {
                        Label("Reconnect", systemImage: "bolt.horizontal.circle")
                    }
                }

                Button {
                    showingPairingImporter = true
                } label: {
                    Label(
                        manager.hasValidExpectedPairingFile ? "Replace Pairing File" : "Select Pairing File",
                        systemImage: "doc.badge.plus"
                    )
                }
            }

            if manager.hasValidExpectedPairingFile {
                Button(role: .destructive) {
                    forgetSharedPairing()
                } label: {
                    Label("Forget Shared Pairing", systemImage: "trash")
                }
            }
        } header: {
            Text("Device Pairing")
        } footer: {
            Text("Shared with ByeTunes. 3105 keeps its normal app discovery and only uses this connection for higher-quality SpringBoard app icons. If pairing or LocalDevVPN is unavailable, the existing LaunchServices icon path is used automatically.")
        }
        .sheet(isPresented: $showingPairingImporter) {
            // Use the exact same document picker and broad pairing-file type set
            // as ByeTunes. SwiftUI's fileImporter was graying out valid pairing
            // files that ByeTunes' UIDocumentPicker accepts on-device.
            DocumentPicker(types: [.data, .xml, .propertyList, .item]) { url in
                handlePairingImport(url: url)
            }
        }
        .alert("Device Pairing", isPresented: $showingMessage) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(message)
        }
        .onAppear {
            manager.refreshExpectedPairingFileState()
        }
    }

    private func handlePairingImport(url: URL?) {
        guard let url else { return }

        do {
            manager.stopHeartbeat()
            try manager.importPairingFile(from: url)
            FilzaSharedPairingSupport.resetAfterPairingChange()
            manager.startHeartbeat(forceReconnect: true) { success in
                Task { @MainActor in
                    message = success
                        ? "Pairing saved for Filza 27 and connected. ByeTunes and 3105 now share this device connection."
                        : "Pairing was saved, but the device tunnel is not connected yet. Enable LocalDevVPN and tap Reconnect."
                    showingMessage = true
                }
            }
        } catch {
            manager.refreshExpectedPairingFileState()
            message = error.localizedDescription
            showingMessage = true
        }
    }

    private func forgetSharedPairing() {
        manager.stopHeartbeat()
        let fileManager = FileManager.default
        for url in [manager.regularPairingFile, manager.rpPairingFile] {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        manager.refreshExpectedPairingFileState()
        FilzaSharedPairingSupport.resetAfterPairingChange()
        message = "Shared pairing removed. ByeTunes and 3105 will ask for a pairing file again when one is required."
        showingMessage = true
    }
}
