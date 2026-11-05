import Foundation

@_silgen_name("FilzaFairPlayEncryptedSlices")
private func fpEncryptedSlices(_ path: UnsafePointer<CChar>) -> Int32
@_silgen_name("FilzaFairPlayDecryptMachO")
private func fpDecryptMachO(
    _ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>,
    _ error: UnsafeMutablePointer<CChar>, _ count: Int
) -> Int32

/// An optional in-process backend. Airlift snapshots alone do not confer
/// Apple's permission to decrypt the original installed Mach-O.
enum FilzaFairPlayBackend {
    enum Failure: LocalizedError {
        case originalUnavailable
        case badPreparedIPA
        case noExecutable
        case denied(String)
        case verification(String)

        var errorDescription: String? {
            switch self {
            case .originalUnavailable:
                return "Original installed app path unavailable. Airlift's staged copy cannot bypass FairPlay's signed-bundle location restrictions."
            case .badPreparedIPA:
                return "The prepared IPA must contain exactly one valid Payload/*.app with the selected bundle identifier."
            case .noExecutable:
                return "No supported arm64 Mach-O was found in the IPA."
            case .denied(let why):
                return "FairPlay mapping failed: \(why). No decrypted IPA was produced."
            case .verification(let file):
                return "Decrypted IPA verification failed for \(file). No decrypted IPA was produced."
            }
        }
    }

    nonisolated private static func encryptedSlices(_ file: URL) -> Int32 {
        file.path.withCString { fpEncryptedSlices($0) }
    }
    nonisolated private static func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let first = try? handle.read(upToCount: 4), first.count == 4 else { return false }
        let magic = UInt32(first[0]) | UInt32(first[1]) << 8 |
            UInt32(first[2]) << 16 | UInt32(first[3]) << 24
        return magic == 0xfeedfacf || magic == 0xbebafeca || magic == 0xbfbafeca
    }

    /// Returns the original IPA if already clear; otherwise a separately
    /// validated decrypted IPA. Never changes the installed app.
    nonisolated static func decryptPreparedIPA(
        bundleID: String, preparedIPA: URL, pairedBundlePath: String?
    ) throws -> URL {
        // Prefer the locally discovered installed bundle. InstallationProxy's
        // paired Airlift metadata supplies a path fallback when local lookup
        // doesn't return a usable bundle location. This does not grant access.
        let localPath = filzaAppBundlePathForBundleID(bundleID)
        let candidates = [localPath, pairedBundlePath].compactMap { $0 }
        guard let path = candidates.first(where: { FilzaAirlift.validBundle($0) }) else {
            throw Failure.originalUnavailable
        }
        // Keep the old bad_query traversal lease alive for direct reads on
        // supported iOS versions. On patched versions this may fail safely.
        let lease = ContainerStore.grantContainerAccess(path)
        defer { if lease >= 0 { bad_query_release(lease) } }
        let originalApp = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "FilzaFairPlay-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.unzipItem(at: preparedIPA, to: temp)
        let payload = temp.appendingPathComponent("Payload", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: []),
              entries.count == 1, let staged = entries.first,
              staged.pathExtension.lowercased() == "app",
              let info = NSDictionary(contentsOf: staged.appendingPathComponent("Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure.badPreparedIPA
        }
        guard let scan = fm.enumerator(at: staged,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure.badPreparedIPA
        }
        var found = 0, decrypted = 0
        while let binary = scan.nextObject() as? URL {
            let v = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v.isRegularFile != true || v.isSymbolicLink == true || !isMachO(binary) { continue }
            found += 1
            let crypt = encryptedSlices(binary)
            if crypt < 0 { throw Failure.verification(binary.lastPathComponent) }
            if crypt == 0 { continue }
            let rel = String(binary.path.dropFirst(staged.path.count + 1))
            let source = originalApp.appendingPathComponent(rel)
            let clear = temp.appendingPathComponent("clear-\(UUID().uuidString)")
            var err = [CChar](repeating: 0, count: 512)
            let errorCapacity = err.count
            let rc = source.path.withCString { src in
                clear.path.withCString { dst in
                    fpDecryptMachO(src, dst, &err, errorCapacity)
                }
            }
            guard rc == 0, encryptedSlices(clear) == 0 else {
                try? fm.removeItem(at: clear)
                throw Failure.denied(String(cString: err))
            }
            let attrs = try? fm.attributesOfItem(atPath: binary.path)
            try fm.removeItem(at: binary)
            try fm.moveItem(at: clear, to: binary)
            if let perms = attrs?[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: binary.path)
            }
            decrypted += 1
        }
        guard found > 0 else { throw Failure.noExecutable }
        if decrypted == 0 { return preparedIPA }

        if let verify = fm.enumerator(at: staged, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let file = verify.nextObject() as? URL {
                if isMachO(file) && encryptedSlices(file) != 0 {
                    throw Failure.verification(file.lastPathComponent)
                }
            }
        }
        if let scan = fm.enumerator(at: staged, includingPropertiesForKeys: [.isDirectoryKey]) {
            var licenseDirectories: [URL] = []
            while let file = scan.nextObject() as? URL {
                if file.lastPathComponent == "SC_Info" {
                    licenseDirectories.append(file)
                    scan.skipDescendants()
                }
            }
            for file in licenseDirectories { try? fm.removeItem(at: file) }
        }
        let result = fm.temporaryDirectory.appendingPathComponent(
            "\(bundleID)-\(UUID().uuidString)-decrypted.ipa"
        )
        do {
            _ = try ZIPArchiveWriter.writeIPA(appBundleURL: staged, to: result, fileManager: fm)
            return result
        } catch {
            try? fm.removeItem(at: result)
            throw error
        }
    }
}
