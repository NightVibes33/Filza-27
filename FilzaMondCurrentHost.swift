import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ObjectiveC.runtime

// Mond is compiled into Filza's process, so its standalone App entry point
// cannot be used directly. These globals mirror mond.swift where the upstream
// source expects process-global state.
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)
var fm = FileManager.default

// Standalone Mond receives these values from its app target rather than from
// Swift source: AccentColor comes from Assets.xcassets, UserDefaults.standard
// belongs to com.roooot.mond, and Bundle.main identifies Mond itself. When Mond
// is hosted inside Filza, make that app-target environment explicit.
enum MondEmbeddedParity {
    static let accentColor = Color(
        red: 0.28529,
        green: 0.44118,
        blue: 0.92451,
        opacity: 1.0
    )

    static let defaults: UserDefaults = {
        let legacy = UserDefaults.standard
        let store = UserDefaults(suiteName: "com.roooot.mond") ?? legacy

        // Preserve state created by older embedded Filza builds once, then keep
        // Mond isolated in the same logical defaults domain as the standalone app.
        let keys = [
            "method",
            "ka_on",
            "token",
            "dismiss_after_import",
            "mg_device_name",
            "atomic_write",
            "ignore_failure"
        ]

        for key in keys where store.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                store.set(value, forKey: key)
            }
        }

        return store
    }()

    static let bundle: Bundle = {
        guard
            let url = Bundle.main.url(forResource: "MondEmbedded", withExtension: "bundle"),
            let bundle = Bundle(url: url)
        else {
            return Bundle.main
        }
        return bundle
    }()
}

var mondCurrentTestPath: String {
    let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("test.txt")

    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    return url.path
}

// Mechanical selector namespace only; behavior matches Mond's
// UIDocumentPickerViewController.fix_init implementation.
extension UIDocumentPickerViewController {
    @objc(filzaMond2_fix_initForOpeningContentTypes:asCopy:)
    fileprivate func filzaMond2_fix_init(
        forOpeningContentTypes contentTypes: [UTType],
        asCopy: Bool
    ) -> UIDocumentPickerViewController {
        filzaMond2_fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

private enum MondEmbeddedRuntime {
    private static var didConfigure = false
    private static var didInstallDocumentPickerFix = false

    @MainActor
    static func configureOnce() {
        guard !didConfigure else { return }
        didConfigure = true

        if !is_debugged() {
            setvbuf(stdout, nil, _IONBF, 0)
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        }

        // Mirror Mond 2.2's standalone defaults. The embedded build does
        // not compile mond.swift, so these defaults must be registered here.
        MondEmbeddedParity.defaults.register(defaults: [
            "method": "bad_query",
            "atomic_write": true
        ])

        if MondEmbeddedParity.defaults.bool(forKey: "ka_on") {
            keep_alive()
        }

        installDocumentPickerCompatibility()

        FilzaDiagnosticsAppend(
            "mond",
            "Mond runtime configured commit=3d91194716ad5f06afdf7e9037e6964e80a4ac29 version=2.2 embedded-parity=accent+defaults+bundle bundle=\(MondEmbeddedParity.bundle.bundleIdentifier ?? "unknown")"
        )
    }

    @MainActor
    private static func installDocumentPickerCompatibility() {
        guard !didInstallDocumentPickerFix else { return }

        let originalSelector = #selector(
            UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)
        )
        let replacementSelector = #selector(
            UIDocumentPickerViewController.filzaMond2_fix_init(forOpeningContentTypes:asCopy:)
        )

        guard
            let original = class_getInstanceMethod(
                UIDocumentPickerViewController.self,
                originalSelector
            ),
            let replacement = class_getInstanceMethod(
                UIDocumentPickerViewController.self,
                replacementSelector
            )
        else {
            return
        }

        method_exchangeImplementations(original, replacement)
        didInstallDocumentPickerFix = true
    }
}

private struct MondEmbeddedRoot: View {
    @StateObject private var state = MondCurrentAppState.shared
    @AppStorage("ka_on", store: MondEmbeddedParity.defaults) private var ka_on = true

    var body: some View {
        FilzaEmbeddedPanel {
            MondCurrentContentView()
                .environmentObject(state)
                .onOpenURL { url in
                    guard is_pb_archive(url) else {
                        print("(mond) ignoring unsupported URL: \(url.lastPathComponent)")
                        return
                    }

                    state.append_poster_file(url)
                }
                .onAppear {
                    if !is_supported() {
                        MondCurrentAlertinator.shared.alert(
                            title: "Not supported!",
                            body: "Your iOS version may not be supported by mond.\nMond only supports iOS 27.0 developer beta 1 - 4."
                        )
                    }

                    grant_all(state: state)
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
}

@MainActor
private final class MondEmbeddedViewController: UIHostingController<MondEmbeddedRoot> {
    override func viewDidLoad() {
        super.viewDidLoad()
        FilzaEmbeddedPanelPresentation.configure(self)
    }
}

@objc(MondEmbeddedHostFactory)
public final class MondEmbeddedHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        MondEmbeddedRuntime.configureOnce()
        let controller = MondEmbeddedViewController(rootView: MondEmbeddedRoot())
        controller.title = "mond"
        FilzaEmbeddedPanelPresentation.configure(controller)

        NSLog(
            "[Filza/Mond] constructed pinned Mond 2.2 root at 3d91194716ad5f06afdf7e9037e6964e80a4ac29"
        )
        return controller
    }
}

// Preserve the older Filza bridge ABI only as a host alias. It returns the same
// pinned Mond root with only the explicit embedded-environment parity adapters.
@objc(MondGestaltHostFactory)
public final class MondGestaltHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(withPath ignoredPath: String) -> UIViewController {
        MondEmbeddedHostFactory.makeViewController()
    }
}
