import Foundation

// The exact Erosion App Decrypt workflow, embedded inside Filza's existing
// 3105 Apps Manager: Airlift app-bundle folder read -> persist prepared .app
// -> Decrypt menu packages Payload/<app>.app. This DOES NOT remove FairPlay.
struct FilzaAirliftIPAResult {
    let fileURL: URL
    let encryptionStatus: String
}
private struct FilzaPreparedAppManifest: Codable {
    let bundleID: String
    let displayName: String
    let sourcePath: String
    let appDirectoryName: String
    let preparedAt: Date
}
enum FilzaAirliftIPAExporter {
    enum ExportError: LocalizedError {
        case missingBundle, invalidBundle, missingExecutable, emptyBundle, unprepared
        var errorDescription: String? {
            switch self {
            case .missingBundle: return "InstallationProxy did not return an installed .app bundle path."
            case .invalidBundle: return "The Airlift app bundle snapshot was invalid."
            case .missingExecutable: return "The app's declared executable is missing."
            case .emptyBundle: return "Airlift returned an empty .app snapshot."
            case .unprepared: return "Prepare this installed app through Airlift first."
            }
        }
    }
    nonisolated private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilzaAirlift/IPA", isDirectory: true)
    }
    nonisolated private static var preparedRoot: URL {
        root.appendingPathComponent("Prepared", isDirectory: true)
    }
    nonisolated private static var exportRoot: URL {
        root.appendingPathComponent("Exports", isDirectory: true)
    }
    nonisolated private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        return cleaned.isEmpty ? "Application" : cleaned
    }

    // Erosion prepared.json is a durable index of actually extracted .app
    // snapshots, not a claim based on InstallationProxy metadata alone.
    nonisolated static func preparedDirectories() -> [String: URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: preparedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var prepared: [String: URL] = [:]
        for entry in entries {
            let manifestURL = entry.appendingPathComponent("prepared.json")
            guard let bytes = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(FilzaPreparedAppManifest.self, from: bytes),
                  let bundle = validatedAppDirectory(
                    entry.appendingPathComponent(manifest.appDirectoryName, isDirectory: true),
                    bundleID: manifest.bundleID
                  ) else { continue }
            prepared[manifest.bundleID] = bundle
        }
        return prepared
    }

    nonisolated private static func validatedAppDirectory(
        _ url: URL, bundleID: String
    ) -> URL? {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              fm.fileExists(atPath: url.path, isDirectory: &directory),
              directory.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: url.path),
              !entries.isEmpty else { return nil }
        // Match Erosion's Prepare: a nonempty snapshot is prepared even if
        // Airlift omits Info.plist or its declared executable. Refuse a
        // definite conflicting bundle ID, but distinguish missing metadata
        // from a failed read and do not falsely claim an installable IPA.
        if let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) as? [String: Any],
           let declared = info["CFBundleIdentifier"] as? String,
           !declared.isEmpty, declared != bundleID {
            return nil
        }
        return url
    }

    // Erosion's source is the paired InstallationProxy bundle path, not an app
    // data container, MCM symlink or a locally reconstructed application.
    static func prepare(_ app: FilzaAirliftApp) async throws -> URL {
        guard let bundlePath = app.bundlePath, FilzaAirlift.validBundle(bundlePath)
        else { throw ExportError.missingBundle }
        let archive = try await FilzaAirlift.snapshot(path: bundlePath, folder: true)
        let bundleID = app.bundleID, displayName = app.name
        return try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: archive) }
            return try installSnapshot(
                archive, bundlePath: bundlePath, bundleID: bundleID, displayName: displayName
            )
        }.value
    }

    // Matches Erosion's installSnapshot layout and executable permission repair.
    nonisolated private static func installSnapshot(
        _ archive: URL, bundlePath: String, bundleID: String, displayName: String
    ) throws -> URL {
        let fm = FileManager.default
        guard bundlePath.hasPrefix("/var/containers/Bundle/Application/") ||
              bundlePath.hasPrefix("/private/var/containers/Bundle/Application/")
        else { throw ExportError.missingBundle }
        let appName = URL(fileURLWithPath: bundlePath).lastPathComponent
        let appStorage = preparedRoot.appendingPathComponent(safeName(bundleID), isDirectory: true)
        let staging = preparedRoot.appendingPathComponent(
            ".Working-\(UUID().uuidString)", isDirectory: true
        )
        let appURL = staging.appendingPathComponent(appName, isDirectory: true)
        // SecureZIPArchive creates the destination itself and rejects an
        // existing directory, avoiding partial overwrite of prepared data.
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // Erosion Airlift folder archives contain .app CONTENTS at ZIP root.
            // SecureZIPArchive refuses path traversal and symlink entries.
            _ = try SecureZIPArchive.extract(archiveURL: archive, destinationURL: appURL)
            guard let items = try? fm.contentsOfDirectory(atPath: appURL.path),
                  !items.isEmpty else { throw ExportError.emptyBundle }
            guard validatedAppDirectory(appURL, bundleID: bundleID) != nil
            else { throw ExportError.invalidBundle }
            if NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) == nil {
                FilzaDiagnosticsAppend("IPA", "Prepared nonempty app snapshot, but Airlift did not expose readable Info.plist; installation may fail")
            }
            try restoreExecutablePermissions(in: appURL)
            let manifest = FilzaPreparedAppManifest(
                bundleID: bundleID, displayName: displayName, sourcePath: bundlePath,
                appDirectoryName: appName, preparedAt: Date()
            )
            let bytes = try JSONEncoder().encode(manifest)
            try bytes.write(
                to: staging.appendingPathComponent("prepared.json"), options: .atomic
            )
            if fm.fileExists(atPath: appStorage.path) {
                try fm.removeItem(at: appStorage)
            }
            try fm.moveItem(at: staging, to: appStorage)
            return appStorage.appendingPathComponent(appName, isDirectory: true)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    nonisolated private static func restoreExecutablePermissions(in app: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: nil)
        else { return }
        var paths = Set<String>()
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "dylib" {
                paths.insert(url.path)
            } else if url.lastPathComponent == "Info.plist",
                      let info = NSDictionary(contentsOf: url) as? [String: Any],
                      let executable = info["CFBundleExecutable"] as? String,
                      !executable.isEmpty, executable != ".", executable != "..",
                      !executable.contains("/") {
                let binary = url.deletingLastPathComponent().appendingPathComponent(executable)
                if fm.fileExists(atPath: binary.path) { paths.insert(binary.path) }
            }
        }
        for path in paths { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    // Erosion's "Decrypt" button means "construct IPA from prepared bundle".
    // Keep this exact semantic; do not claim FairPlay was actually removed.
    nonisolated static func makeIPA(
        from prepared: URL, displayName: String, bundleID: String
    ) throws -> FilzaAirliftIPAResult {
        guard validatedAppDirectory(prepared, bundleID: bundleID) != nil
        else { throw ExportError.unprepared }
        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let working = root.appendingPathComponent(
            "Working-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: working) }
        let payload = working.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.copyItem(
            at: prepared, to: payload.appendingPathComponent(prepared.lastPathComponent)
        )
        let name = safeName(displayName)
        let zip = working.appendingPathComponent("\(name).zip")
        try fm.zipItem(at: payload, to: zip, shouldKeepParent: true)
        let exported = exportRoot.appendingPathComponent(
            "\(name)-\(UUID().uuidString.prefix(8)).ipa"
        )
        try fm.moveItem(at: zip, to: exported)
        let status = (try? inspectIPA(exported))
            ?? "IPA repackaged; executable metadata not verified, FairPlay unchanged"
        FilzaDiagnosticsAppend("IPA", "Erosion IPA packaging succeeded: \(exported.lastPathComponent); \(status)")
        return FilzaAirliftIPAResult(fileURL: exported, encryptionStatus: status)
    }

    // Retain API compatibility for existing callers, but single-step export
    // is never used by the main Apps Manager's Prepare -> Decrypt flow.
    static func export(_ app: FilzaAirliftApp) async throws -> FilzaAirliftIPAResult {
        let prepared = try await prepare(app)
        return try await Task.detached(priority: .utility) {
            try makeIPA(from: prepared, displayName: app.name, bundleID: app.bundleID)
        }.value
    }

    /// Inspect the prepared IPA's real executable, without modifying FairPlay.
    nonisolated static func inspectIPA(_ ipaURL: URL) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FilzaIPAVerify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.unzipItem(at: ipaURL, to: root)
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: [.isDirectoryKey]
        ), let appURL = entries.first(where: { $0.pathExtension.lowercased() == "app" }),
              let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/") else { throw ExportError.invalidBundle }
        let bin = appURL.appendingPathComponent(executable)
        guard fm.fileExists(atPath: bin.path) else { throw ExportError.missingExecutable }
        return encryptionStatus(bin)
    }

    nonisolated private static func encryptionStatus(_ executableURL: URL) -> String {
        guard let bytes = try? Data(contentsOf: executableURL, options: .mappedIfSafe)
        else { return "Unknown — executable unreadable" }
        func readU32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            return UInt32(bytes[offset]) |
                UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 |
                UInt32(bytes[offset + 3]) << 24
        }
        guard let magic = readU32(0), magic == 0xfeedfacf || magic == 0xfeedface,
              let commandCount = readU32(16), commandCount < 50_000 else {
            return "Unknown — unsupported Mach-O layout"
        }
        var position = magic == 0xfeedfacf ? 32 : 28
        for _ in 0..<commandCount {
            guard let command = readU32(position),
                  let commandSize = readU32(position + 4),
                  commandSize >= 8,
                  Int(commandSize) <= bytes.count - position else { break }
            if command == 0x21 || command == 0x2c {
                guard let cryptID = readU32(position + 16) else { break }
                return cryptID == 0 ? "Not FairPlay-encrypted" : "FairPlay-encrypted — not decrypted"
            }
            position += Int(commandSize)
        }
        return "No encryption load command found"
    }
}