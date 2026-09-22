import SwiftUI
import UIKit

private struct Filza3105EmbeddedRoot: View {
    let initialTab: Int
    let initialImportURL: URL?

    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
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
                .environmentObject(patchStore)
                .environmentObject(repositoryStore)
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
                    "routed external 3105 import into embedded Installed workspace"
                )
            }
            FilzaDiagnosticsAppend(
                "3105",
                "canonical embedded 2.0 panel visible initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "upstream 3105 2.0 marketplace, schema-v3 patches and restore workflow active"
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
            initialTab: AppSection.home.rawValue,
            title: "3105",
            diagnostic: "constructing full upstream 3105 2.0 workspace"
        )
    }

    @objc public static func makeAppsManagerController() -> UIViewController {
        makeController(
            initialTab: AppSection.files.rawValue,
            title: "Apps Manager",
            diagnostic: "constructing 3105 2.0 Files/Apps Manager"
        )
    }

    @objc public static func makePatchesController() -> UIViewController {
        makeController(
            initialTab: AppSection.installed.rawValue,
            title: "Patches",
            diagnostic: "constructing 3105 2.0 Installed/Patches"
        )
    }

    @objc(makePatchesImportControllerWithURL:)
    public static func makePatchesImportController(withURL url: URL) -> UIViewController {
        makeController(
            initialTab: AppSection.installed.rawValue,
            title: "Patches",
            diagnostic: "constructing 3105 2.0 Installed/Patches for external import",
            initialImportURL: url
        )
    }
}
