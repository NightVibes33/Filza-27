#!/usr/bin/env bash
set -euo pipefail

NETWORK="ByeTunes/MusicManager/MetadataBackgroundURLSession.swift"
test -f "$NETWORK"

python3 - "$NETWORK" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def replace_braced_block(text: str, start_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        if replacement in text:
            return text
        raise SystemExit(f"{label}: start marker not found")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"{label}: opening brace not found")
    depth = 0
    in_string = False
    escape = False
    i = brace
    while i < len(text):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[:start] + replacement + text[i + 1:]
        i += 1
    raise SystemExit(f"{label}: closing brace not found")

# Preserve pinned ByeTunes v2.4 provider/settings behavior. The device log shows
# a transport failure, not a parser failure: music.apple.com, itunes.apple.com
# and api.deezer.com all return NSURLErrorCannotFindHost while the Wi-Fi path is
# satisfied. Only replace the shared network dispatcher. URLSession remains the
# primary transport; foreground metadata GETs retry DNS-resolution failures via
# WebKit's separate networking process. The original background URLSession route
# remains byte-for-byte equivalent at its call sites.
text = replace_once(text, "import Foundation\n", "import Foundation\nimport WebKit\n", "WebKit import")

replacement = r'''
@MainActor
private final class FilzaMetadataWebRequest: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var webView: WKWebView?
    private var finished = false

    func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.navigationDelegate = self
            webView.load(request)

            perform(#selector(timeoutRequest), with: nil, afterDelay: 18.0)
        }
    }

    @objc private func timeoutRequest() {
        guard !finished else { return }
        finish(.failure(URLError(.timedOut)))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard !finished else { return }
        finished = true
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        response = navigationResponse.response
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        let isHTML = response?.mimeType?.lowercased().contains("html") == true
        if isHTML {
            perform(#selector(extractDocument), with: nil, afterDelay: 0.35)
        } else {
            extractDocument()
        }
    }

    @objc private func extractDocument() {
        guard !finished, let webView else { return }
        let isHTML = response?.mimeType?.lowercased().contains("html") == true
        let script = isHTML
            ? "document.documentElement ? document.documentElement.outerHTML : ''"
            : "document.body ? document.body.innerText : (document.documentElement ? document.documentElement.innerText : '')"

        webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
            guard let self, let webView, !self.finished else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8) else {
                self.finish(.failure(URLError(.cannotDecodeContentData)))
                return
            }

            let response = self.response ?? URLResponse(
                url: webView.url ?? URL(string: "about:blank")!,
                mimeType: isHTML ? "text/html" : "text/plain",
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            self.finish(.success((data, response)))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

private enum FilzaMetadataWebFallback {
    @MainActor
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await FilzaMetadataWebRequest().run(request)
    }
}

enum SongMetadataNetworking {
    @TaskLocal static var useBackgroundSession: Bool = false

    private static func shouldRetryThroughWebKit(_ request: URLRequest, error: Error) -> Bool {
        guard request.httpMethod == nil || request.httpMethod == "GET" else { return false }
        guard let urlError = error as? URLError,
              urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed else { return false }
        guard let host = request.url?.host?.lowercased() else { return false }

        if host == "music.apple.com" || host == "itunes.apple.com" || host == "api.deezer.com" {
            return true
        }
        if host == "www.youtube.com" || host.hasSuffix(".youtube.com") { return true }
        if host.contains("invidious") || host.contains("piped") { return true }
        if host == "lrclib.net" || host == "api.lrclib.net" { return true }
        return false
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Exact upstream background route.
        if useBackgroundSession {
            return try await MetadataBackgroundURLSession.shared.data(for: request)
        }

        do {
            // Exact upstream foreground transport remains primary.
            return try await URLSession.shared.data(for: request)
        } catch {
            let primaryError = error
            guard shouldRetryThroughWebKit(request, error: primaryError) else {
                throw primaryError
            }

            let host = request.url?.host ?? "unknown"
            Logger.shared.log("[MetadataNetwork] URLSession DNS failed for \\(host); retrying through WebKit network process")
            do {
                let result = try await FilzaMetadataWebFallback.data(for: request)
                Logger.shared.log("[MetadataNetwork] WebKit fallback succeeded host=\\(host) bytes=\\(result.0.count)")
                return result
            } catch let fallbackError {
                Logger.shared.log("[MetadataNetwork] WebKit fallback failed host=\\(host): \\(fallbackError)")
                throw primaryError
            }
        }
    }

    static func data(from url: URL) async throws -> (Data, URLResponse) {
        // Preserve exact upstream background behavior.
        if useBackgroundSession {
            return try await MetadataBackgroundURLSession.shared.data(from: url)
        }
        return try await data(for: URLRequest(url: url))
    }
}
'''

text = replace_braced_block(text, "enum SongMetadataNetworking {", replacement.strip(), "SongMetadataNetworking")
path.write_text(text)
PY

grep -Fq 'import WebKit' "$NETWORK"
grep -Fq 'FilzaMetadataWebRequest' "$NETWORK"
grep -Fq 'return try await MetadataBackgroundURLSession.shared.data(for: request)' "$NETWORK"
grep -Fq 'return try await URLSession.shared.data(for: request)' "$NETWORK"
grep -Fq 'retrying through WebKit network process' "$NETWORK"
grep -Fq 'WebKit fallback succeeded host=' "$NETWORK"
! grep -Fq 'filzaMetadataSourcesRepairV2' "$NETWORK"

echo "Verified minimal ByeTunes DNS fallback without provider/settings rewrites"
