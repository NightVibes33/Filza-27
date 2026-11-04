import Foundation

/// CoreMedia is a read-only DATA SOURCE for Filza's original file browser.
/// Only verified bytes are copied to a sandbox-local mirror inside Device Storage.
/// There is no independent Erosion tab or another file-browser interface.
@MainActor
@objc(FilzaNativeCoreMediaBridge)
public final class FilzaNativeCoreMediaBridge: NSObject {
    private static let systemFolder = "SYSTEM PATHS - READ-ONLY"
    private static let subtree = ["CoreMedia", "usr", "libexec"]
    private static let readyNotification = "FilzaNativeCoreMediaDirectoryReady"
    private static var prepared = false
    private static var loading = Set<String>()
    private static var completed = Set<String>()

    private static func mirrorRoot() -> URL {
        var root = URL(fileURLWithPath: MCMFilzaVirtualRoot(), isDirectory: true)
            .appendingPathComponent(systemFolder, isDirectory: true)
        for component in subtree {
            root.appendPathComponent(component, isDirectory: true)
        }
        return root
    }

    /// Called by TGFileSystemListViewController, never by an embedded 3105/Erosion UI.
    @objc public static func prepareNativeRoot() {
        if prepared { return }
        let fm = FileManager.default
        let storage = URL(fileURLWithPath: MCMFilzaVirtualRoot(), isDirectory: true)
        var folder = storage
        let components = [systemFolder] + subtree
        do {
            for component in components {
                folder.appendPathComponent(component, isDirectory: true)
                // Never traverse a user-replaced symlink under Device Storage.
                guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
                    throw NSError(domain: "FilzaCoreMedia", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Refusing symlink in system mirror"])
                }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let readme = storage.appendingPathComponent(systemFolder, isDirectory: true)
                .appendingPathComponent("README - READ ONLY.txt")
            if !fm.fileExists(atPath: readme.path) {
                let message = "This is Filza's native Device Storage browser.\n\n" +
                    "CoreMedia /usr/libexec is a read-only, on-demand local mirror of files " +
                    "actually returned by the CoreMedia XPC reader. Opening libexec starts " +
                    "a background scan. Filza refreshes the same folder after the scan. " +
                    "Opening a subfolder loads that subfolder on demand.\n\n" +
                    "The original system files are never changed. This is NOT root access. " +
                    "Unreadable, oversized or denied files are omitted and recorded in " +
                    "ACCESS STATUS.txt. An unavailable backend is reported, not faked.\n"
                try message.write(to: readme, atomically: true, encoding: .utf8)
            }
            prepared = true
        } catch {
            FilzaDiagnosticsAppend("CoreMedia", "Native Device Storage root failed: " +
                                   error.localizedDescription)
        }
    }

    /// Native Filza asks for each folder as its own normal path.
    @objc public static func refreshNativeDirectory(_ requestedPath: String) {
        guard prepared else { return }
        let normalized = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        let root = mirrorRoot().standardizedFileURL.path
        guard normalized == root || normalized.hasPrefix(root + "/") else { return }
        guard !loading.contains(normalized), !completed.contains(normalized) else { return }

        // A symlink inside the mirror must not redirect this read-only projection.
        guard URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path == normalized else {
            FilzaDiagnosticsAppend("CoreMedia", "Refused symlinked mirror path")
            return
        }
        loading.insert(normalized)
        let remote = "/usr/libexec" + String(normalized.dropFirst(root.count))
        Task.detached(priority: .utility) {
            var report = ""
            do {
                report = try materialize(remote: remote, into: normalized)
            } catch {
                report = "CoreMedia read unavailable: " + error.localizedDescription
                // The folder remains in Filza with an explicit failure explanation.
                try? report.write(to: URL(fileURLWithPath: normalized)
                    .appendingPathComponent("ACCESS STATUS.txt"),
                    atomically: true, encoding: .utf8)
            }
            await MainActor.run {
                loading.remove(normalized)
                completed.insert(normalized)
                FilzaDiagnosticsAppend("CoreMedia", "Native Filza " + remote + ": " + report)
                NotificationCenter.default.post(
                    name: Notification.Name(readyNotification),
                    object: nil, userInfo: ["path": normalized]
                )
            }
        }
    }

    /// Do all CoreMedia/XPC work off the main thread. Only genuine data is
    /// published, bounded by per-file and per-directory memory/storage limits.
    nonisolated private static func materialize(remote: String, into localPath: String) throws -> String {
        let fm = FileManager.default
        let local = URL(fileURLWithPath: localPath, isDirectory: true)
        guard (try? fm.destinationOfSymbolicLink(atPath: localPath)) == nil else {
            throw NSError(domain: "FilzaCoreMedia", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Mirror target is a symlink"])
        }
        let entries = try FilzaCoreMediaReader.listDirectory(
            at: URL(fileURLWithPath: remote, isDirectory: true)
        )
        // Read-only permissions still permit re-opening the folder to stage
        // additional genuine bytes on next launch.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localPath)
        defer { try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localPath) }

        let maxFileBytes: Int64 = 64 * 1024 * 1024
        let maxDirectoryBytes: Int64 = 256 * 1024 * 1024
        var stagedBytes: Int64 = 0
        var stagedFiles = 0
        var folders = 0
        var skipped: [String] = []

        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0"),
                  entry.path == remote + "/" + name else {
                skipped.append("Unsafe entry rejected")
                continue
            }
            let destination = local.appendingPathComponent(name, isDirectory: entry.isDirectory)
            if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                skipped.append(name + ": existing symlink")
                continue
            }
            if entry.isDirectory {
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)
                    folders += 1
                } catch {
                    skipped.append(name + ": " + error.localizedDescription)
                }
                continue
            }
            guard entry.size >= 0, entry.size <= maxFileBytes,
                  entry.size <= maxDirectoryBytes - stagedBytes else {
                skipped.append(name + ": exceeded read-only preview limit")
                continue
            }
            do {
                if !fm.fileExists(atPath: destination.path) {
                    let bytes = try FilzaCoreMediaReader.readFileData(
                        atPath: entry.path, maximumBytes: Int(maxFileBytes)
                    )
                    guard Int64(bytes.count) <= maxDirectoryBytes - stagedBytes else {
                        skipped.append(name + ": directory storage limit")
                        continue
                    }
                    try bytes.write(to: destination, options: .atomic)
                    stagedBytes += Int64(bytes.count)
                }
                try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
                stagedFiles += 1
            } catch {
                skipped.append(name + ": " + error.localizedDescription)
            }
        }
        let report = "Source: " + remote + "\n" +
            "Provider: CoreMedia XPC read-only bytestream\n" +
            "Projection: sandbox-local copies in native Filza Device Storage\n" +
            "Directories: " + String(folders) + "\n" +
            "Verified local files: " + String(stagedFiles) + "\n" +
            "Omitted/failed: " + String(skipped.count) + "\n\n" +
            skipped.prefix(30).joined(separator: "\n") + "\n\n" +
            "Editing or deleting a local copy cannot modify the original system path.\n"
        try report.write(to: local.appendingPathComponent("ACCESS STATUS.txt"),
                         atomically: true, encoding: .utf8)
        return "files=" + String(stagedFiles) + " directories=" + String(folders) +
            " omitted=" + String(skipped.count)
    }
}
