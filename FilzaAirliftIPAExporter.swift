import Foundation

/// Adapted from Erosion's Prepare -> IPA workflow. This *repackages* the
/// readable app bundle; it never decrypts FairPlay or impersonates a signer.
struct FilzaAirliftIPAResult {
    let fileURL: URL
    let encryptionStatus: String
}
enum FilzaAirliftIPAExporter {
    enum ExportError: LocalizedError {
        case missingBundle, invalidBundle, missingExecutable
        var errorDescription: String? {
            switch self {
            case .missingBundle: return "InstallationProxy did not provide a valid installed .app path."
            case .invalidBundle: return "The prepared snapshot did not contain a valid .app Info.plist."
            case .missingExecutable: return "The prepared .app executable could not be located."
            }
        }
    }

    static func export(_ app: FilzaAirliftApp) async throws -> FilzaAirliftIPAResult {
        guard let bundlePath = app.bundlePath, FilzaAirlift.validBundle(bundlePath)
        else { throw ExportError.missingBundle }
        // Erosion's Airlift folder ZIP has the contents of the .app at its root.
        let archive = try await FilzaAirlift.snapshot(path: bundlePath, folder: true)
        return try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let workspace = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FilzaAirlift/IPA", isDirectory: true)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let working = workspace.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: working) }
            let payload = working.appendingPathComponent("Payload", isDirectory: true)
            let appName = URL(fileURLWithPath: bundlePath).lastPathComponent
            let appURL = payload.appendingPathComponent(appName, isDirectory: true)
            try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
            try fm.unzipItem(at: archive, to: appURL)
            let infoURL = appURL.appendingPathComponent("Info.plist")
            guard let plist = NSDictionary(contentsOf: infoURL) as? [String: Any]
            else { throw ExportError.invalidBundle }
            guard let executableName = plist["CFBundleExecutable"] as? String,
                  !executableName.isEmpty,
                  executableName != ".", executableName != "..",
                  !executableName.contains("/")
            else { throw ExportError.missingExecutable }
            let executableURL = appURL.appendingPathComponent(executableName)
            guard fm.fileExists(atPath: executableURL.path) else { throw ExportError.missingExecutable }

            // AFC ZIP snapshots may lose executable bits. Restore declared
            // bundle binaries without changing Mach-O content or code signatures.
            if let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) {
                for case let file as URL in enumerator {
                    if file.pathExtension == "dylib" {
                        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                    } else if file.lastPathComponent == "Info.plist",
                              let subInfo = NSDictionary(contentsOf: file) as? [String: Any],
                              let subExecutable = subInfo["CFBundleExecutable"] as? String,
                              !subExecutable.contains("/"), !subExecutable.isEmpty {
                        let bin = file.deletingLastPathComponent().appendingPathComponent(subExecutable)
                        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
                    }
                }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            let status = encryptionStatus(executableURL)
            let cleaned = app.name.replacingOccurrences(
                of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression
            )
            let finalName = cleaned.isEmpty ? "Application" : cleaned
            let destination = workspace.appendingPathComponent("\(finalName)-\(UUID().uuidString.prefix(8)).ipa")
            try fm.zipItem(at: payload, to: destination, shouldKeepParent: true)
            FilzaDiagnosticsAppend("Airlift", "IPA repackaged; FairPlay status: \(status)")
            return FilzaAirliftIPAResult(fileURL: destination, encryptionStatus: status)
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