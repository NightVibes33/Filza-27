import Foundation
import UIKit

/// Native Filza filesystem bridge for Erosion/Airlift-style folder reads.
/// The paired reader returns a ZIP only as a transport artifact. We validate
/// and extract the folder into Filza's existing Device Storage tree, then
/// navigate the ORIGINAL TGFileSystemListViewController to that directory.
/// No separate file manager, Erosion tab, or visible ZIP is created.
@MainActor
@objc(FilzaNativeAirliftFolderBridge)
public final class FilzaNativeAirliftFolderBridge: NSObject {
    private static var browsing = false
    // Old builds exposed ZIPs under Device Storage/[Airlift] Snapshots.
    // Remove ONLY that exact old generated symlink, never a user folder.
    @objc public static func retireLegacyArchiveShortcut() {
        let fm = FileManager.default
        let alias = URL(fileURLWithPath: MCMFilzaVirtualRoot(), isDirectory: true)
            .appendingPathComponent("[Airlift] Snapshots")
        let original = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilzaAirlift/Snapshots", isDirectory: true)
        guard let oldTarget = try? fm.destinationOfSymbolicLink(atPath: alias.path),
              URL(fileURLWithPath: oldTarget).standardizedFileURL.path ==
                original.standardizedFileURL.path else { return }
        do {
            try fm.removeItem(at: alias)
            FilzaDiagnosticsAppend("NativeAirlift", "Retired legacy ZIP shortcut; actual archives remain private")
        } catch {
            FilzaDiagnosticsAppend("NativeAirlift", "Legacy shortcut removal denied: " + error.localizedDescription)
        }
    }



    @objc public static func browseFolder(
        _ remotePath: String,
        fromBrowser browser: UIViewController
    ) {
        guard !browsing else {
            showNotice("A paired folder read is already running.", from: browser)
            return
        }
        guard remotePath.hasPrefix("/"),
              !remotePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              remotePath != "/" else {
            showNotice("Choose a specific absolute folder path without . or .. components.", from: browser)
            return
        }
        if FilzaAirlift.restorationStopped {
            showNotice("SAFETY STOP: a previous Airlift read did not confirm source-folder restoration. Further remote reads are blocked until recovery is verified.", from: browser)
            return
        }
        guard FilzaAirlift.pairedRecord() != nil else {
            showNotice("Set up Device Pairing in Filza Settings and enable LocalDevVPN.", from: browser)
            return
        }
        browsing = true
        Task {
            defer { browsing = false }
            do {
                let archive = try await FilzaAirlift.snapshot(path: remotePath, folder: true)
                let fm = FileManager.default
                let storage = URL(fileURLWithPath: MCMFilzaVirtualRoot(), isDirectory: true)
                let parent = storage.appendingPathComponent("Paired Folders", isDirectory: true)
                // Use a fresh, uniquely named folder: no symlink traversal and
                // no risk of overwriting a previously browsed local snapshot.
                let leaf = URL(fileURLWithPath: remotePath).lastPathComponent
                let safeLeaf = String(leaf.unicodeScalars.map { scalar in
                    CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                        ? Character(scalar) : "_"
                }.prefix(48))
                let target = parent.appendingPathComponent(
                    (safeLeaf.isEmpty ? "Folder" : safeLeaf) + "-" + UUID().uuidString,
                    isDirectory: true
                )
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                // Erosion uses the same Airlift folder transport + local
                // extraction. SecureZIPArchive additionally rejects traversal,
                // symlinks and oversized/malformed entries.
                let extraction = try await Task.detached(priority: .utility) {
                    try SecureZIPArchive.extract(archiveURL: archive, destinationURL: target)
                }.value
                try? fm.removeItem(at: archive)

                // These are copies only. Make local snapshots read-only so the
                // browser never implies editing the protected source in place.
                if let enumerator = fm.enumerator(at: target,
                    includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                    while let path = enumerator.nextObject() as? URL {
                        let isDir = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        try? fm.setAttributes(
                            [.posixPermissions: isDir ? 0o555 : 0o444],
                            ofItemAtPath: path.path
                        )
                    }
                }
                try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
                FilzaDiagnosticsAppend(
                    "NativeAirlift",
                    "Opened verified folder " + remotePath +
                    " in native Filza browser; files=" + String(extraction.fileCount) +
                    " bytes=" + String(extraction.expandedBytes)
                )

                // Only the original Filza navigation controller owns the file
                // tree. No SwiftUI file browser is ever presented.
                let setPath = NSSelectorFromString("setCurrentPath:")
                let load = NSSelectorFromString("doLoadingPage")
                guard browser.responds(to: setPath) else {
                    showNotice("Filza's original folder navigation is unavailable.", from: browser)
                    return
                }
                _ = browser.perform(setPath, with: target.path)
                if browser.responds(to: load) {
                    _ = browser.perform(load)
                }
            } catch {
                FilzaDiagnosticsAppend("NativeAirlift", "Folder browse failed: " + error.localizedDescription)
                showNotice(error.localizedDescription, from: browser)
            }
        }
    }

    private static func showNotice(_ message: String, from browser: UIViewController) {
        let alert = UIAlertController(
            title: "Paired Folder Access", message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let presenter = browser.presentedViewController ?? browser
        if presenter is UIAlertController {
            browser.dismiss(animated: false) {
                browser.present(alert, animated: true)
            }
        } else {
            presenter.present(alert, animated: true)
        }
    }
}
