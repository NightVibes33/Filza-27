import SwiftUI
import UIKit

private struct Filza3105AppsRoot: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftCoordinator = PatchDraftCoordinator()
    @StateObject private var patchStore = PatchProjectStore()

    var body: some View {
        AppDataBrowserView()
            .environmentObject(draftCoordinator)
            .environment(\.appLanguage, .english)
            .environment(\.locale, AppLanguage.english.locale)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    patchStore.create(project: project, password: password)
                    draftCoordinator.clear()
                }
                .environment(\.appLanguage, .english)
                .environment(\.locale, AppLanguage.english.locale)
            }
    }
}

private struct Filza3105PatchesRoot: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftCoordinator = PatchDraftCoordinator()

    var body: some View {
        PatchProjectsView()
            .environmentObject(draftCoordinator)
            .environment(\.appLanguage, .english)
            .environment(\.locale, AppLanguage.english.locale)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}

@objc(Filza3105HostFactory)
public final class Filza3105HostFactory: NSObject {
    @objc public static func makeAppsManagerController() -> UIViewController {
        FilzaDiagnosticsAppend("3105", "constructing complete 3105 Apps Manager")
        let controller = UIHostingController(rootView: Filza3105AppsRoot())
        controller.title = "Apps Manager"
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    @objc public static func makePatchesController() -> UIViewController {
        FilzaDiagnosticsAppend("3105", "constructing complete 3105 Patches")
        let controller = UIHostingController(rootView: Filza3105PatchesRoot())
        controller.title = "Patches"
        controller.modalPresentationStyle = .fullScreen
        return controller
    }
}
