import Combine
import Foundation

struct PatchDraftRequest: Identifiable {
    let id = UUID()
    let draft: PatchProjectDraft
}

@MainActor
final class PatchDraftCoordinator: ObservableObject {
    @Published var request: PatchDraftRequest?

    func present(_ draft: PatchProjectDraft) {
        request = PatchDraftRequest(draft: draft)
    }

    func clear() {
        request = nil
    }
}
