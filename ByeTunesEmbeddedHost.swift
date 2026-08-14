import SwiftUI
import UIKit

private final class ByeTunesEmbeddedNavigationController: UINavigationController {
    @objc func closeEmbeddedByeTunes() {
        dismiss(animated: true)
    }
}

private func makeMusicLibraryHost() -> UIViewController {
    FilzaDiagnosticsWriteByeTunesStage("before direct Music Library ContentView construction")
    let root = ContentView()
    FilzaDiagnosticsWriteByeTunesStage("direct Music Library ContentView constructed")
    let host = UIHostingController(rootView: root)
    host.title = "Music Library"
    host.view.backgroundColor = .systemGroupedBackground
    FilzaDiagnosticsWriteByeTunesStage("direct Music Library SwiftUI host ready")
    return host
}

/// Hosts the complete music application immediately. Its process-global device
/// work is made inert by patch-byetunes-embedded.sh, so no intermediate UIKit
/// loading controller or branded splash is needed.
@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
    @objc(handleBackgroundEventsForSessionIdentifier:completionHandler:)
    public static func handleBackgroundEvents(
        forSessionIdentifier identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        if identifier == MetadataBackgroundURLSession.sessionIdentifier {
            guard BackgroundMetadataFetchManager.isEnabled else {
                completionHandler()
                return true
            }
            MetadataBackgroundURLSession.shared.setBackgroundEventsCompletionHandler(completionHandler)
            BackgroundMetadataFetchManager.shared.processPendingDownloadsInBackground()
            return true
        }

        guard identifier == BackgroundAudioDownloadManager.sessionIdentifier else {
            return false
        }
        guard UserDefaults.standard.bool(forKey: "backgroundDownloadsEnabled") else {
            completionHandler()
            return true
        }
        BackgroundAudioDownloadManager.shared.setBackgroundEventsCompletionHandler(completionHandler)
        return true
    }

    @objc(makeLibraryViewController)
    public static func makeLibraryViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("direct Music Library factory entered")
        return makeMusicLibraryHost()
    }

    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("standalone Music Library factory entered")
        let host = makeMusicLibraryHost()
        let navigation = ByeTunesEmbeddedNavigationController(rootViewController: host)
        host.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: navigation,
            action: #selector(ByeTunesEmbeddedNavigationController.closeEmbeddedByeTunes)
        )
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }
}
