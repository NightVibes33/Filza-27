import SwiftUI
import UIKit

private struct Filza3105EmbeddedRoot: View {
    let initialTab: Int
    let initialImportURL: URL?

    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var routedInitialImport = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some View {
        FilzaEmbeddedPanel {
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
                "canonical embedded panel visible initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "full upstream 3105 1.1.1 workspace appeared initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "1.1.1 navigation active: responsive layout, independent Files tabs, Patch Workspace v2, updated support backend"
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
        FilzaEmbeddedPanelPresentation.configure(controller)
        return controller
    }

    @objc public static func makeHomeController() -> UIViewController {
        makeController(
            initialTab: 0,
            title: "3105",
            diagnostic: "constructing full upstream 3105 1.1.1 workspace"
        )
    }

    @objc public static func makeAppsManagerController() -> UIViewController {
        makeController(
            initialTab: 1,
            title: "Apps Manager",
            diagnostic: "constructing complete 3105 1.1.1 Apps Manager"
        )
    }

    @objc public static func makePatchesController() -> UIViewController {
        makeController(
            initialTab: 2,
            title: "Patches",
            diagnostic: "constructing complete 3105 1.1.1 Patches"
        )
    }

    @objc(makePatchesImportControllerWithURL:)
    public static func makePatchesImportController(withURL url: URL) -> UIViewController {
        makeController(
            initialTab: 2,
            title: "Patches",
            diagnostic: "constructing 3105 1.1.1 Patches for external import",
            initialImportURL: url
        )
    }
}
