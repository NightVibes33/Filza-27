import Foundation
import SwiftUI
import UIKit

// Current mond is compiled into Filza as source rather than launched as a
// second UIApplication. These globals preserve mond's standalone runtime
// contracts used by LogView and PosterBoard helpers.
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)
var fm = FileManager.default

private enum MondEmbeddedRuntime {
    private static var didConfigure = false

    @MainActor
    static func configureOnce() {
        guard !didConfigure else { return }
        didConfigure = true

        // Match mond's standalone stdout capture so the real upstream LogView
        // receives exploit/tweak output. Filza's persistent diagnostics use a
        // separate file-backed logger and are not dependent on stdout.
        if !is_debugged() {
            setvbuf(stdout, nil, _IONBF, 0)
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        }

        // Keep both keys because current upstream ContentView/Settings use
        // "method", while mond's standalone App init still registers the older
        // "exploit_method" default. This preserves upstream behavior without
        // allowing the Filza host to choose a different initial method.
        UserDefaults.standard.register(defaults: [
            "exploit_method": "bad_query",
            "method": "bad_query",
            "ka_on": true
        ])

        if UserDefaults.standard.bool(forKey: "ka_on") {
            keep_alive()
        }

        FilzaDiagnosticsAppend(
            "mond",
            "current upstream runtime configured commit=4a37bfca5cb4abb2c99891972365d872d700525e"
        )
    }
}

private struct MondEmbeddedRoot: View {
    @StateObject private var state = MondCurrentAppState()
    @State private var didAppear = false

    var body: some View {
        MondCurrentContentView()
            .environmentObject(state)
            .onAppear {
                guard !didAppear else { return }
                didAppear = true

                MondEmbeddedRuntime.configureOnce()
                if !is_supported() {
                    MondCurrentAlertinator.shared.alert(
                        title: "Not supported!",
                        body: "Your iOS version may not be supported by mond.\nMond only supports iOS 27.0 beta 1 - beta 4."
                    )
                }

                grant_all(state: state)
                FilzaDiagnosticsAppend(
                    "mond",
                    "current upstream ContentView appeared full-screen; access initialization started"
                )
            }
            .overlay {
                if state.show_respring {
                    MondCurrentRespringView()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                        .onAppear {
                            print("(respring) respringing now...")
                        }
                }
            }
    }
}

// Mond is a standalone full-screen app upstream. Presenting its root as a
// pageSheet changes the navigation geometry, safe-area height, list proportions
// and the visible grabber. Use a full-screen host so the staged upstream views
// render with the same screen geometry. A two-finger swipe down is retained as
// an integration-only escape gesture without adding UI that is not in mond.
@MainActor
private final class MondEmbeddedViewController: UIHostingController<MondEmbeddedRoot> {
    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen

        let dismissGesture = UISwipeGestureRecognizer(
            target: self,
            action: #selector(dismissEmbeddedMond)
        )
        dismissGesture.direction = .down
        dismissGesture.numberOfTouchesRequired = 2
        view.addGestureRecognizer(dismissGesture)
    }

    @objc private func dismissEmbeddedMond() {
        FilzaDiagnosticsAppend("mond", "full-screen mond dismissed by two-finger swipe")
        dismiss(animated: true)
    }
}

@objc(MondEmbeddedHostFactory)
public final class MondEmbeddedHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        MondEmbeddedRuntime.configureOnce()
        let controller = MondEmbeddedViewController(rootView: MondEmbeddedRoot())
        controller.title = "mond"
        controller.modalPresentationStyle = .fullScreen
        FilzaDiagnosticsAppend(
            "mond",
            "constructed full-screen current mond root at 4a37bfca5cb4abb2c99891972365d872d700525e"
        )
        return controller
    }
}

// Keep the old Objective-C factory ABI so existing quick-action/tooling probes
// do not break. It no longer creates the old Gestalt-only reconstruction: every
// legacy call is forwarded to the complete current mond root.
@objc(MondGestaltHostFactory)
public final class MondGestaltHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(withPath ignoredPath: String) -> UIViewController {
        MondEmbeddedHostFactory.makeViewController()
    }
}
