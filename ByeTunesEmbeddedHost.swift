import SwiftUI
import UIKit

private final class ByeTunesEmbeddedNavigationController: UINavigationController {
    @objc func closeEmbeddedByeTunes() {
        dismiss(animated: true)
    }
}

/// Hosts the complete ByeTunes SwiftUI application inside Filza's process.
/// `makeLibraryViewController()` is the actual Filza Music Library port: it
/// returns the unmodified ByeTunes ContentView without wrapping/presenting a
/// second app-style modal controller.
@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
    @objc(makeLibraryViewController)
    public static func makeLibraryViewController() -> UIViewController {
        let host = UIHostingController(rootView: ContentView())
        host.view.backgroundColor = .systemGroupedBackground
        return host
    }

    /// Retained for callers that intentionally need a standalone presentation,
    /// such as a future shortcut/fallback route. Filza's Music Library itself
    /// uses `makeLibraryViewController()` and embeds the returned controller.
    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        let host = UIHostingController(rootView: ContentView())
        host.title = "ByeTunes"

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
