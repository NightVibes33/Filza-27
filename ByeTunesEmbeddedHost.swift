import SwiftUI
import UIKit

/// Replaces only ByeTunes' standalone `@main` application shell. Every
/// original ByeTunes screen and service is compiled into this same module and
/// the unmodified `ContentView` remains the app root.
@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: ContentView())
        controller.title = "ByeTunes"
        controller.modalPresentationStyle = .fullScreen
        return controller
    }
}
