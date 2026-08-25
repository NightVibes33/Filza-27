import Combine
import Foundation

struct PatchDraftRequest: Identifiable {
    let id = UUID()
    let draft: PatchProjectDraft
}

enum PatchImportSource: Equatable {
    case file(URL)
    case remote(URL)
    case invalid
}

enum PatchImportRoute {
    static let urlScheme = "threeoneosfive"

    static func resolve(_ incomingURL: URL) -> PatchImportSource {
        if incomingURL.isFileURL {
            return incomingURL.pathExtension.lowercased() == "3105"
                ? .file(incomingURL)
                : .invalid
        }

        if validatedRemoteURL(incomingURL) != nil {
            return .remote(incomingURL)
        }

        guard incomingURL.scheme?.lowercased() == urlScheme,
              incomingURL.host?.lowercased() == "import",
              let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let rawRemoteURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remoteURL = URL(string: rawRemoteURL),
              validatedRemoteURL(remoteURL) != nil else {
            return .invalid
        }
        return .remote(remoteURL)
    }

    static func validatedRemoteURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}

struct PatchImportRequest: Identifiable, Equatable {
    let id = UUID()
    let source: PatchImportSource
}

@MainActor
final class PatchDraftCoordinator: ObservableObject {
    @Published var request: PatchDraftRequest?
    @Published var importRequest: PatchImportRequest?

    func present(_ draft: PatchProjectDraft) {
        request = PatchDraftRequest(draft: draft)
    }

    func clear() {
        request = nil
    }

    func presentImport(_ url: URL) {
        importRequest = PatchImportRequest(source: PatchImportRoute.resolve(url))
    }

    func clearImport() {
        importRequest = nil
    }
}
