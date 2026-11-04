import Foundation
import SwiftUI
import AirliftFFI

/// Optional Erosion/Airlift backend. Existing 3105, Mond, bad_query, CMG,
/// MobileHouseArrest and LaunchServices backends remain independent on iOS 18-27.
struct FilzaAirliftApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let dataPath: String?
    let bundlePath: String?
    var id: String { bundleID }
}
struct FilzaAirliftCatalog {
    let apps: [FilzaAirliftApp]
    let appGroups: [String]
}
enum FilzaAirliftError: LocalizedError {
    case unpaired, invalidPath, failed(String), unsafeRecovery(String)
    var errorDescription: String? {
        switch self {
        case .unpaired:
            return "No shared RP or NFCARD pairing record was found. Start on-device RP pairing in NFCARD or ByeTunes, then enable LocalDevVPN. The local 3105 browser remains available."
        case .invalidPath: return "An absolute path without . or .. components is required."
        case .failed(let message): return message
        case .unsafeRecovery(let detail):
            return "SAFETY STOP: the remote directory was not confirmed restored. Do not open its app until recovery is resolved. " + detail
        }
    }
}
enum FilzaAirlift {
    private struct Reply {
        let status: Int32
        let json: String?
        let error: String?
    }
    /// ByeTunes/3105 own the canonical validated RPPairing record under
    /// "pairing file/rpPairingFile.plist" (possibly in the app group). NFCARD
    /// owns Documents/aircard_pairing.plist. NFCARD's pairingFilePath() scans
    /// only the *top level* of Documents, so it misses the shared RP record.
    /// Reuse either in place, without exporting credentials or creating copies.
    private static func readableRecord(at path: String) -> Bool {
        let fm = FileManager.default
        return fm.isReadableFile(atPath: path)
            && ((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
    }

    private static func pairingChoice() -> (path: String, source: String)? {
        let sharedRP = DeviceManager.shared.rpPairingFile.path
        if readableRecord(at: sharedRP) {
            return (sharedRP, "shared ByeTunes/3105 RP pairing")
        }
        let nfcard = PairingController.pairingFilePath()
        if readableRecord(at: nfcard) {
            return (nfcard, "NFCARD on-device pairing")
        }
        return nil
    }

    static func pairedRecord() -> String? { pairingChoice()?.path }
    static func pairingSource() -> String {
        pairingChoice()?.source ?? "no readable shared RP or NFCARD record"
    }
    private static func checkPath(_ source: String) throws -> String {
        let path = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw FilzaAirliftError.invalidPath }
        return path
    }
    nonisolated private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { al_string_free(pointer) }
        return String(cString: pointer)
    }
    private static func call(
        pairing: String,
        run: @escaping (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) async -> Reply {
        await Task.detached(priority: .utility) {
            var json: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = pairing.withCString { run($0, &json, &error) }
            return Reply(status: status, json: takeString(json), error: takeString(error))
        }.value
    }
    private static func decoded(_ reply: Reply) throws -> [String: Any] {
        guard reply.status == 0, let json = reply.json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FilzaAirliftError.failed(reply.error ?? reply.json ?? "Airlift returned an error (\(reply.status)).") }
        return object
    }
    private static func normalize(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
    static func validBundle(_ path: String) -> Bool {
        let value = normalize(path)
        let prefix = "/var/containers/Bundle/Application/"
        guard value.hasPrefix(prefix) else { return false }
        let parts = value.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
            && String(parts[1]).lowercased().hasSuffix(".app")
    }
    static func discover() async throws -> FilzaAirliftCatalog {
        guard let choice = pairingChoice() else {
            FilzaDiagnosticsAppend("Airlift", "Scan blocked: no readable shared RP or NFCARD record")
            throw FilzaAirliftError.unpaired
        }
        FilzaDiagnosticsAppend("Airlift", "InstallationProxy scan starting via \(choice.source)")
        let reply = await call(pairing: choice.path) { al_list_app_containers($0, nil, nil, $1, $2) }
        let result: [String: Any]
        do {
            result = try decoded(reply)
        } catch {
            FilzaDiagnosticsAppend(
                "Airlift",
                "InstallationProxy scan failed via \(choice.source): \(error.localizedDescription)"
            )
            throw error
        }
        var apps: [String: FilzaAirliftApp] = [:]
        for item in (result["applications"] as? [[String: Any]]) ?? [] {
            guard let id = item["bundleID"] as? String, !id.isEmpty else { continue }
            let candidate = item["container"] as? String
            // Accept both InstallationProxy path roots, as Erosion does.
            let dataPath = candidate.map(normalize).flatMap {
                ($0.hasPrefix("/var/mobile/Containers/Data/Application/")
                 || $0.hasPrefix("/var/containers/Data/Application/")) ? $0 : nil
            }
            apps[id] = .init(bundleID: id, name: id, dataPath: dataPath, bundlePath: nil)
        }
        for item in (result["bundles"] as? [[String: Any]]) ?? [] {
            guard let id = item["bundleID"] as? String, !id.isEmpty else { continue }
            let previous = apps[id]
            let title = (item["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (item["path"] as? String).map(normalize)
            apps[id] = .init(
                bundleID: id,
                name: title.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.name ?? id,
                dataPath: previous?.dataPath,
                bundlePath: candidate.flatMap { validBundle($0) ? $0 : nil }
            )
        }
        var groups = ((result["appGroups"] as? [[String: Any]]) ?? [])
            .compactMap { $0["container"] as? String }
            .map(normalize).filter { $0.hasPrefix("/var/mobile/Containers/Shared/AppGroup/") }
        // Erosion also provides an AFC-only directory-entry probe. It never
        // reads app-group file contents and may simply return no paths when
        // the OS denies AppGroup enumeration.
        if groups.isEmpty {
            let fallback = await call(pairing: choice.path) {
                al_list_app_group_container_paths($0, nil, nil, $1, $2)
            }
            if let response = try? decoded(fallback) {
                groups += ((response["paths"] as? [String]) ?? [])
                    .map(normalize).filter { $0.hasPrefix("/var/mobile/Containers/Shared/AppGroup/") }
            }
        }
        let discovered = apps.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let rawApplications = (result["applications"] as? [[String: Any]])?.count ?? 0
        let rawBundles = (result["bundles"] as? [[String: Any]])?.count ?? 0
        let acceptedData = discovered.filter { $0.dataPath != nil }.count
        let acceptedBundles = discovered.filter { $0.bundlePath != nil }.count
        FilzaDiagnosticsAppend(
            "Airlift",
            "InstallationProxy returned \(rawApplications) data and \(rawBundles) bundle rows; " +
            "recognized \(discovered.count) apps (\(acceptedData) data paths, \(acceptedBundles) bundle paths). " +
            "Paths are metadata, not direct filesystem permissions."
        )
        return .init(apps: discovered, appGroups: Array(Set(groups)).sorted())
    }
    /// Airlift's read is a staging/restore transaction, not normal sandbox
    /// access. Copy only complete results into our independent local workspace.
    static func snapshot(path original: String, folder: Bool) async throws -> URL {
        guard let pairing = pairedRecord() else { throw FilzaAirliftError.unpaired }
        let target = try checkPath(original)
        let reply = await call(pairing: pairing) { record, outJSON, outError in
            target.withCString { remote in
                if folder {
                    return al_exploit_read_folder(record, remote, nil, nil, outJSON, outError)
                }
                return al_exploit_read_file(record, remote, nil, nil, outJSON, outError)
            }
        }
        let result: [String: Any]
        do {
            result = try decoded(reply)
        } catch {
            let detail = reply.error ?? reply.json ?? ""
            if folder && (detail.lowercased().contains("restore") ||
                          detail.lowercased().contains("recover")) {
                throw FilzaAirliftError.unsafeRecovery(detail)
            }
            throw error
        }
        // Both InstallationProxy root spellings require explicit proof of
        // restoration; a path alias must never bypass the safety stop.
        let canonicalTarget = normalize(target)
        let protectedAppContainer = [
            "/var/mobile/Containers/Data/Application",
            "/var/containers/Data/Application"
        ].contains { canonicalTarget == $0 || canonicalTarget.hasPrefix($0 + "/") }
        if folder && (
            (result["partial"] as? Bool) == true ||
            (result["restoreConfirmed"] as? Bool) == false ||
            (result["restoreHandoffCompleted"] as? Bool) == false ||
            result["restoreError"] != nil ||
            (protectedAppContainer && ((result["restoreConfirmed"] as? Bool) != true ||
                                       (result["restoreHandoffCompleted"] as? Bool) != true))
        ) {
            throw FilzaAirliftError.unsafeRecovery(
                result["recoveryPath"] as? String ??
                result["restoreError"] as? String ??
                "See Airlift recovery diagnostics."
            )
        }
        guard let local = result["localPath"] as? String,
              FileManager.default.isReadableFile(atPath: local)
        else { throw FilzaAirliftError.failed("The device did not return an accessible snapshot.") }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilzaAirlift/Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = folder ? "zip" : (URL(fileURLWithPath: target).pathExtension.isEmpty
            ? "bin" : URL(fileURLWithPath: target).pathExtension)
        let saved = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: local), to: saved)
        // Filza's native Device Storage root contains an alias to the same
        // snapshots. It is an ordinary sandbox-local symlink, not a sandbox
        // escape or an automatically synchronized device filesystem.
        let nativeRoot = URL(fileURLWithPath: MCMFilzaVirtualRoot(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
            let alias = nativeRoot.appendingPathComponent("[Airlift] Snapshots")
            if !FileManager.default.fileExists(atPath: alias.path) {
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            }
        } catch {
            FilzaDiagnosticsAppend("Airlift", "native Device Storage snapshot alias unavailable: \(error.localizedDescription)")
        }
        FilzaDiagnosticsAppend("Airlift", "saved snapshot of \(target) to \(saved.lastPathComponent)")
        return saved
    }
    /// Applies one user-selected local file only when the paired Airlift write
    /// primitive actually returns success; never claim unrestricted / access.
    static func writeFolder(localURL: URL, remoteDirectory original: String) async throws {
        guard let pairing = pairedRecord() else { throw FilzaAirliftError.unpaired }
        let target = try checkPath(original)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &directory),
              directory.boolValue
        else { throw FilzaAirliftError.failed("Selected local source is not a readable folder.") }
        let reply = await call(pairing: pairing) { record, _, outError in
            localURL.path.withCString { source in
                target.withCString { destination in
                    al_exploit_write_dir(record, source, destination, nil, nil, outError)
                }
            }
        }
        guard reply.status == 0 else {
            throw FilzaAirliftError.failed(reply.error ?? "Airlift denied the folder write.")
        }
    }
    static func removeRemote(path original: String) async throws {
        guard let pairing = pairedRecord() else { throw FilzaAirliftError.unpaired }
        let target = try checkPath(original)
        let components = target.split(separator: "/")
        guard components.count >= 4,
              !["/var/mobile/Containers", "/var/mobile/Media", "/var/mobile/Library",
                 "/var/mobile/Containers/Data/Application",
                 "/var/mobile/Containers/Shared/AppGroup"].contains(target)
        else { throw FilzaAirliftError.invalidPath }
        let reply = await call(pairing: pairing) { record, _, outError in
            target.withCString { remote in
                al_exploit_remove_path(record, remote, nil, nil, outError)
            }
        }
        guard reply.status == 0 else {
            throw FilzaAirliftError.failed(reply.error ?? "Airlift denied the removal.")
        }
    }

    static func writeFile(localURL: URL, remotePath original: String) async throws {
        guard let pairing = pairedRecord() else { throw FilzaAirliftError.unpaired }
        let target = try checkPath(original)
        guard FileManager.default.isReadableFile(atPath: localURL.path)
        else { throw FilzaAirliftError.failed("Source file cannot be read.") }
        let reply = await call(pairing: pairing) { record, _, outError in
            localURL.path.withCString { source in
                target.withCString { destination in
                    al_exploit_write_file(record, source, destination, nil, nil, outError)
                }
            }
        }
        guard reply.status == 0 else {
            throw FilzaAirliftError.failed(reply.error ?? "Airlift refused the file write.")
        }
    }
}

@MainActor final class FilzaAirliftCatalogStore: ObservableObject {
    static let shared = FilzaAirliftCatalogStore()
    @Published private(set) var apps: [FilzaAirliftApp] = []
    @Published private(set) var appGroups: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var message = "Not scanned"
    private init() {}
    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            do {
                let result = try await FilzaAirlift.discover()
                apps = result.apps
                appGroups = result.appGroups
                let dataCount = apps.filter { $0.dataPath != nil }.count
                let bundleCount = apps.filter { $0.bundlePath != nil }.count
                message = "InstallationProxy: \(apps.count) apps (\(dataCount) data, \(bundleCount) bundles), \(appGroups.count) groups"
            } catch {
                // A pairing/tunnel failure invalidates the remote catalog.
                // Keeping stale rows would misrepresent actual app discovery.
                apps = []
                appGroups = []
                message = error.localizedDescription
            }
            FilzaDiagnosticsAppend("Airlift", message)
            scanning = false
        }
    }
}