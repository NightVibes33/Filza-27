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

        UserDefaults.standard.register(defaults: [
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
                    "current upstream ContentView appeared; access initialization started"
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

@objc(MondEmbeddedHostFactory)
public final class MondEmbeddedHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        MondEmbeddedRuntime.configureOnce()
        let controller = UIHostingController(rootView: MondEmbeddedRoot())
        controller.title = "mond"
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        FilzaDiagnosticsAppend(
            "mond",
            "constructed full current mond root at 4a37bfca5cb4abb2c99891972365d872d700525e"
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
