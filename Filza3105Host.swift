import SwiftUI
import UIKit

private struct Filza3105EmbeddedRoot: View {
    let initialTab: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var originalAppsUnavailable = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }

                Spacer(minLength: 12)

                Button {
                    if !Filza3105PresentOriginalAppsFromController(nil) {
                        originalAppsUnavailable = true
                    }
                } label: {
                    Label("Filza Apps", systemImage: "square.grid.2x2")
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            ThreeOneOSFiveContentView(initialTab: initialTab)
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
        }
        .alert("Filza Apps Manager unavailable", isPresented: $originalAppsUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The original Filza Apps Manager could not be constructed in this build.")
        }
        .onAppear {
            appState.detectSupport()
            FilzaDiagnosticsAppend(
                "3105",
                "persistent Close and Filza Apps controls visible initialTab=\(initialTab)"
            )
            FilzaDiagnosticsAppend(
                "3105",
                "full upstream workspace appeared initialTab=\(initialTab)"
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
        diagnostic: String
    ) -> UIViewController {
        FilzaDiagnosticsAppend("3105", diagnostic)
        let controller = UIHostingController(
            rootView: Filza3105EmbeddedRoot(initialTab: initialTab)
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
            diagnostic: "constructing full upstream 3105 workspace"
        )
    }

    @objc public static func makeAppsManagerController() -> UIViewController {
        makeController(
            initialTab: 1,
            title: "Apps Manager",
            diagnostic: "constructing complete 3105 Apps Manager"
        )
    }

    @objc public static func makePatchesController() -> UIViewController {
        makeController(
            initialTab: 2,
            title: "Patches",
            diagnostic: "constructing complete 3105 Patches"
        )
    }
}
