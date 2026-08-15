import SwiftUI
import UIKit

private struct Filza3105EmbeddedRoot: View {
    let initialTab: Int
    let initialImportURL: URL?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var routedInitialImport = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }

                Spacer()
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            ThreeOneOSFiveContentView(initialTab: initialTab)
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
        }
        .onAppear {
            appState.detectSupport()
            if !routedInitialImport, let initialImportURL {
                routedInitialImport = true
                patchDraftCoordinator.presentImport(initialImportURL)
                FilzaDiagnosticsAppend(
                    "3105",
                    "routed external 3105 import into embedded Patches workspace"
                )
            }
            FilzaDiagnosticsAppend(
                "3105",
                "persistent Close control visible initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "full upstream 3105 1.0 workspace appeared initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "complete tabs linked Home/Files/Patches/Cleaner/Wallpapers/Settings/Logs"
            )
        }
    }
}

@objc(Filza3105HostFactory)
public final class Filza3105HostFactory: NSObject {
    private static func makeController(
        initialTab: Int,
        title: String,
        diagnostic: String,
        initialImportURL: URL? = nil
    ) -> UIViewController {
        FilzaDiagnosticsAppend("3105", diagnostic)
        let controller = UIHostingController(
            rootView: Filza3105EmbeddedRoot(
                initialTab: initialTab,
                initialImportURL: initialImportURL
            )
        )
        controller.title = title
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return controller
    }

    @objc public static func makeHomeController() -> UIViewController {
        makeController(
            initialTab: 0,
            title: "3105",
            diagnostic: "constructing full upstream 3105 1.0 workspace"
        )
    }

    @objc public static func makeAppsManagerController() -> UIViewController {
        makeController(
            initialTab: 1,
            title: "Apps Manager",
            diagnostic: "constructing complete 3105 1.0 Apps Manager"
        )
    }

    @objc public static func makePatchesController() -> UIViewController {
        makeController(
            initialTab: 2,
            title: "Patches",
            diagnostic: "constructing complete 3105 1.0 Patches"
        )
    }

    @objc(makePatchesImportControllerWithURL:)
    public static func makePatchesImportController(withURL url: URL) -> UIViewController {
        makeController(
            initialTab: 2,
            title: "Patches",
            diagnostic: "constructing 3105 1.0 Patches for external import",
            initialImportURL: url
        )
    }
}
