import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A single pairing-record owner for Filza 27 and all embedded tools.
/// The validated RPPairing record remains in ByeTunes DeviceManager's
/// existing canonical location. No credentials are logged or exported.
@MainActor
enum FilzaUnifiedPairingManager {
    // Read-only snapshot. Never call refreshExpectedPairingFileState() or
    // PairingController.pairingFilePath() from SwiftUI body: both can mutate
    // observed state. The latter can also copy candidate pairing records.
    static func recordPath() -> String? {
        let manager = DeviceManager.shared
        if manager.hasValidExpectedPairingFile {
            return manager.rpPairingFile.path
        }
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        var candidates = [
            docs.appendingPathComponent("aircard_pairing.plist").path,
            docs.appendingPathComponent("airlift_pairing.plist").path
        ]
        if let custom = PairingController.customPairingFilePath {
            candidates.insert(custom, at: 0)
        }
        let fm = FileManager.default
        return candidates.first { path in
            fm.isReadableFile(atPath: path) &&
            ((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        }
    }

    static func recordSource(for path: String?) -> String {
        if DeviceManager.shared.hasValidExpectedPairingFile {
            return "Shared RP pairing (ByeTunes / 3105 / Airlift / NFCARD)"
        }
        return path == nil ? "None" : "Legacy NFCARD/Airlift pairing record"
    }

    static func synchronize(reason: String) {
        DeviceManager.shared.refreshExpectedPairingFileState()
        FilzaSharedPairingSupport.resetAfterPairingChange()
        AppViewModel.shared?.refreshPairingFile()
        AppViewModel.shared?.refreshNetworkStatus()
        let path = recordPath()
        FilzaDiagnosticsAppend(
            "Pairing",
            "Unified record changed: \(reason); source=\(recordSource(for: path)); " +
            "record available=\(path != nil)"
        )
        FilzaAirliftCatalogStore.shared.refresh()
    }
}

private struct FilzaUnifiedPairingSettings: View {
    @ObservedObject private var manager = DeviceManager.shared
    @ObservedObject private var onDevice = ByeTunesOnDevicePairingController.shared
    @ObservedObject private var airlift = FilzaAirliftCatalogStore.shared
    @State private var showImporter = false
    @State private var showForgetConfirmation = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    // Keep status as a snapshot. Re-reading and publishing pairing state from
    // body creates an ObservableObject -> body -> publish feedback loop.
    @State private var recordLabel = "Checking…"
    @State private var recordAvailable = false

    private func refreshDisplayedRecord() {
        manager.refreshExpectedPairingFileState()
        let path = FilzaUnifiedPairingManager.recordPath()
        recordLabel = FilzaUnifiedPairingManager.recordSource(for: path)
        recordAvailable = path != nil
    }

    var body: some View {
        Form {
            Section("Shared device connection") {
                LabeledContent("Pairing record", value: recordLabel)
                LabeledContent("Required format", value: manager.expectedPairingFileTitle)
                LabeledContent("Device tunnel", value: manager.heartbeatReady
                    && FilzaSharedPairingSupport.hasActiveTransport
                    ? "Connected" : manager.connectionStatus)
                LabeledContent("Airlift", value: airlift.message)
                    .font(.caption)
                Text("Filza, NFCARD, ByeTunes, Apps Manager and Erosion/Airlift " +
                     "use the same pairing record. A stored record alone does not " +
                     "guarantee that LocalDevVPN or a remote read/write succeeds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pair this iPhone") {
                Button {
                    onDevice.start(manager: manager)
                } label: {
                    Label(onDevice.isPairing ? "Pairing…" : "Start on-device pairing",
                          systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
                .disabled(onDevice.isPairing)
                if onDevice.isPairing { ProgressView() }
                Text(onDevice.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let pin = onDevice.pin {
                    LabeledContent("Pairing PIN", value: pin)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("On iOS 27: Settings → Privacy & Security → Developer Mode " +
                     "→ Pair with ByeTunes. Approve the request and enter the PIN.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Import an existing pairing record") {
                Button {
                    showImporter = true
                } label: {
                    Label("Select pairing file", systemImage: "doc.badge.plus")
                }
                Text("Select a valid RP pairing file from Files. The selected " +
                     "file is validated and installed into the same private record " +
                     "location used by on-device pairing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection tools") {
                Button {
                    FilzaUnifiedPairingManager.synchronize(reason: "manual refresh")
                    refreshDisplayedRecord()
                    manager.startHeartbeat(forceReconnect: true)
                } label: {
                    Label("Reconnect and refresh all modules", systemImage: "arrow.clockwise")
                }
                .disabled(!recordAvailable)
                if recordAvailable {
                    Button(role: .destructive) {
                        showForgetConfirmation = true
                    } label: {
                        Label("Forget pairing on this iPhone", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Device Pairing")
        .task {
            // A single refresh after presentation is safe. Do not launch
            // discovery/reconnection merely by opening the Settings screen.
            refreshDisplayedRecord()
        }
        .onChange(of: onDevice.status) { value in
            if value.hasPrefix("Paired.") {
                FilzaUnifiedPairingManager.synchronize(reason: "on-device RP pairing completed")
                refreshDisplayedRecord()
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try manager.importPairingFile(from: url)
                FilzaUnifiedPairingManager.synchronize(reason: "imported validated RP record")
                refreshDisplayedRecord()
                manager.startHeartbeat(forceReconnect: true)
                alertMessage = "Pairing imported. Enable LocalDevVPN if the tunnel is disconnected."
            } catch {
                alertMessage = "Pairing import failed: \(error.localizedDescription)"
                FilzaDiagnosticsAppend("Pairing", "import failed: \(error.localizedDescription)")
            }
            showAlert = true
        }
        .confirmationDialog(
            "Forget all locally stored pairing records?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget pairing", role: .destructive) {
                let manager = DeviceManager.shared
                let docs = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask)[0]
                let locations = [
                    manager.rpPairingFile, manager.regularPairingFile,
                    docs.appendingPathComponent("aircard_pairing.plist"),
                    docs.appendingPathComponent("airlift_pairing.plist")
                ]
                for file in locations {
                    try? FileManager.default.removeItem(at: file)
                }
                PairingController.customPairingFilePath = nil
                manager.stopHeartbeat()
                FilzaUnifiedPairingManager.synchronize(reason: "user forgot records")
                refreshDisplayedRecord()
                alertMessage = "Local pairing records cleared. No remote device settings were changed."
                showAlert = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Filza's saved pairing records for every embedded module.")
        }
        .alert("Device Pairing", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
}

@MainActor @objc(FilzaUnifiedPairingHostFactory)
public final class FilzaUnifiedPairingHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: FilzaUnifiedPairingSettings())
        controller.title = "Device Pairing"
        return controller
    }
}
