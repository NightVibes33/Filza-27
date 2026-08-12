import SwiftUI
import UIKit

private final class ByeTunesEmbeddedNavigationController: UINavigationController {
    @objc func closeEmbeddedByeTunes() {
        dismiss(animated: true)
    }
}

/// Replaces only ByeTunes' standalone `@main` application shell. Every
/// original ByeTunes screen and service is compiled into this same module and
/// the unmodified `ContentView` remains the app root.
@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
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
