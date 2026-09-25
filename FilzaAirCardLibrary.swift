import SwiftUI
@preconcurrency import WebKit
import UIKit

private enum FilzaAirCardLibraryConfig {
    static let homeURL = URL(string: "https://cardmaker-omega.vercel.app")!
    static let allowedHost = "cardmaker-omega.vercel.app"
    static let messageHandler = "aircardLibraryDownload"

    static var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("AirCardCardLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private final class FilzaAirCardLibraryModel: ObservableObject {
    @Published var statusText: String?
    @Published var lastDownloadedName = ""
    @Published var lastDownloadedImage: UIImage?
    @Published var showDownloadActions = false

    weak var webView: WKWebView?

    func didSaveImage(_ image: UIImage, name: String) {
        lastDownloadedImage = image
        lastDownloadedName = name
        statusText = "Saved \(name) in AirCard Card Library"
        showDownloadActions = true
    }

    func fail(_ message: String) {
        statusText = message
    }
}

struct FilzaAirCardLibraryView: View {
    @EnvironmentObject private var vm: AppViewModel
    @StateObject private var model = FilzaAirCardLibraryModel()

    var body: some View {
        FilzaAirCardLibraryWebView(model: model)
            .confirmationDialog(
                "Card saved",
                isPresented: $model.showDownloadActions,
                titleVisibility: .visible
            ) {
                if model.lastDownloadedImage != nil && vm.cards.contains(where: { $0.isSelected }) {
                    Button("Apply to Selected Wallet Cards") {
                        if let image = model.lastDownloadedImage {
                            vm.setSkinForAllCards(image: image)
                        }
                    }
                }

                Button("Keep in Card Library", role: .cancel) {}
            } message: {
                Text(model.lastDownloadedName.isEmpty
                    ? "The card was saved to AirCard."
                    : "\(model.lastDownloadedName) was saved to AirCard.")
            }
            .alert(
                "Library Error",
                isPresented: Binding(
                    get: { model.statusText != nil },
                    set: { if !$0 { model.statusText = nil } }
                )
            ) {
                Button("OK") { model.statusText = nil }
            } message: {
                Text(model.statusText ?? "")
            }
    }
}

private struct FilzaAirCardLibraryWebView: UIViewRepresentable {
    @ObservedObject var model: FilzaAirCardLibraryModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: FilzaAirCardLibraryConfig.messageHandler)
        contentController.addUserScript(
            WKUserScript(
                source: Self.downloadBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.limitsNavigationsToAppBoundDomains = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground

        model.webView = webView
        webView.load(URLRequest(
            url: FilzaAirCardLibraryConfig.homeURL,
            cachePolicy: .useProtocolCachePolicy
        ))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.webView = webView
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: FilzaAirCardLibraryConfig.messageHandler
        )
        webView.navigationDelegate = nil
    }

    private static let downloadBridgeScript = #"""
    (() => {
      if (window.__filzaAirCardLibraryBridgeInstalled) return;
      window.__filzaAirCardLibraryBridgeInstalled = true;

      const post = (payload) => {
        try {
          window.webkit.messageHandlers.aircardLibraryDownload.postMessage(payload);
        } catch (_) {}
      };

      document.addEventListener('click', async (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const anchor = target ? target.closest('a[download]') : null;
        if (!anchor) return;

        const href = anchor.href || anchor.getAttribute('href') || '';
        if (!href) return;

        const filename = anchor.getAttribute('download') || 'card.png';

        if (href.startsWith('blob:') || href.startsWith('data:')) {
          event.preventDefault();
          try {
            const response = await fetch(href);
            const blob = await response.blob();
            const reader = new FileReader();
            reader.onloadend = () => post({
              kind: 'dataURL',
              filename,
              dataURL: String(reader.result || '')
            });
            reader.readAsDataURL(blob);
          } catch (error) {
            post({ kind: 'error', message: String(error) });
          }
          return;
        }

        if (/^https?:/i.test(href)) {
          event.preventDefault();
          post({ kind: 'url', filename, url: href });
        }
      }, true);
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        private let model: FilzaAirCardLibraryModel
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]

        init(model: FilzaAirCardLibraryModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.statusText = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.fail("Card Library unavailable offline until it has been cached at least once.")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            model.fail(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.scheme == "about" || url.host?.lowercased() == FilzaAirCardLibraryConfig.allowedHost {
                decisionHandler(.allow)
                return
            }

            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let destination = Self.uniqueDestination(for: suggestedFilename)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let key = ObjectIdentifier(download)
            guard let url = downloadDestinations.removeValue(forKey: key) else { return }
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                try? FileManager.default.removeItem(at: url)
                model.fail("The downloaded file was not an image.")
                return
            }
            model.didSaveImage(image, name: url.lastPathComponent)
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: url)
            }
            model.fail("Card download failed: \(error.localizedDescription)")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == FilzaAirCardLibraryConfig.messageHandler,
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }

            if kind == "error" {
                model.fail((body["message"] as? String) ?? "Card download failed.")
                return
            }

            let filename = (body["filename"] as? String) ?? "card.png"

            if kind == "dataURL",
               let raw = body["dataURL"] as? String,
               let comma = raw.firstIndex(of: ","),
               raw[..<comma].contains(";base64") {
                let encoded = String(raw[raw.index(after: comma)...])
                guard let data = Data(base64Encoded: encoded) else {
                    model.fail("Could not decode the downloaded card image.")
                    return
                }
                persistImage(data: data, suggestedFilename: filename)
                return
            }

            if kind == "url",
               let raw = body["url"] as? String,
               let url = URL(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Task {
                    do {
                        var request = URLRequest(url: url)
                        request.cachePolicy = .returnCacheDataElseLoad
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse,
                           !(200...299).contains(http.statusCode) {
                            throw URLError(.badServerResponse)
                        }
                        persistImage(data: data, suggestedFilename: filename)
                    } catch {
                        model.fail("Card download failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func persistImage(data: Data, suggestedFilename: String) {
            guard let image = UIImage(data: data) else {
                model.fail("The downloaded file was not a supported image.")
                return
            }

            let destination = Self.uniqueDestination(for: suggestedFilename)
            do {
                try data.write(to: destination, options: .atomic)
                model.didSaveImage(image, name: destination.lastPathComponent)
            } catch {
                model.fail("Could not save card image: \(error.localizedDescription)")
            }
        }

        private static func uniqueDestination(for suggestedFilename: String) -> URL {
            let cleaned = sanitizeFilename(suggestedFilename)
            let nsName = cleaned as NSString
            var stem = nsName.deletingPathExtension
            var ext = nsName.pathExtension
            if stem.isEmpty { stem = "card" }
            if ext.isEmpty { ext = "png" }

            let directory = FilzaAirCardLibraryConfig.downloadsDirectory
            var candidate = directory.appendingPathComponent("\(stem).\(ext)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
                suffix += 1
            }
            return candidate
        }

        private static func sanitizeFilename(_ value: String) -> String {
            let raw = (value as NSString).lastPathComponent
            let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            let parts = raw.components(separatedBy: invalid).filter { !$0.isEmpty }
            let joined = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? "card.png" : joined
        }
    }
}
