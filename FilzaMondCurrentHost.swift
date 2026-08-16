import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ObjectiveC.runtime

// Mond 2.0 is compiled into Filza's process, so its standalone App entry point
// cannot be used directly. These globals mirror mond.swift exactly where the
// upstream source expects process-global state.
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)
var fm = FileManager.default

var mondCurrentTestPath: String {
    let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("test.txt")

    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    return url.path
}

// Mechanical selector namespace only; behavior matches Mond 2.0's
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

        UserDefaults.standard.register(defaults: ["exploit_method": "bad_query"])

        if UserDefaults.standard.bool(forKey: "ka_on") {
            keep_alive()
        }

        installDocumentPickerCompatibility()

        FilzaDiagnosticsAppend(
            "mond",
            "Mond 2.0 runtime configured commit=87b38b2726160c6d1cfacbbfa834a2572d7ca333"
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
    @StateObject private var state = MondCurrentAppState()
    @AppStorage("ka_on") private var ka_on = true

    var body: some View {
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

@MainActor
private final class MondEmbeddedViewController: UIHostingController<MondEmbeddedRoot> {
    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen
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
            "constructed exact Mond 2.0 root at 87b38b2726160c6d1cfacbbfa834a2572d7ca333"
        )
        return controller
    }
}

// Preserve the older Filza bridge ABI only as a mechanical host alias. It
// returns the same unmodified Mond 2.0 root.
@objc(MondGestaltHostFactory)
public final class MondGestaltHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(withPath ignoredPath: String) -> UIViewController {
        MondEmbeddedHostFactory.makeViewController()
    }
}
