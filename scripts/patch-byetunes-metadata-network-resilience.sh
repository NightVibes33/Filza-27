#!/usr/bin/env bash
set -euo pipefail

NETWORK="ByeTunes/MusicManager/MetadataBackgroundURLSession.swift"
COMPAT="ByeTunesMetadataCompat.swift"

test -f "$NETWORK"
test -f "$COMPAT"

python3 - "$NETWORK" "$COMPAT" <<'PY'
from pathlib import Path
import sys

network = Path(sys.argv[1])
compat = Path(sys.argv[2])


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


# ---------------------------------------------------------------------------
# Provider-state repair.
#
# Older Filza embedded builds migrated a missing pre-v2.4 provider selection to
# Local Files and persisted that result. That turns every remote provider off,
# even though the embedded build restores the All Sources picker. Repair only
# that exact old embedded default once. Any later explicit user selection is
# left alone because the versioned repair flag is already set.
# ---------------------------------------------------------------------------
ct = compat.read_text()
repair_anchor = '''    static let legacySourceKey = "metadataSource"\n'''
repair_code = '''    static let legacySourceKey = "metadataSource"
    private static let filzaRepairKey = "filzaMetadataSourcesRepairV2"

    private static func repairFilzaEmbeddedDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: filzaRepairKey) else { return }
        defer { defaults.set(true, forKey: filzaRepairKey) }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard bundleID == "com.apple.mobile.MobileHouseArrest" else { return }

        let picker = (defaults.string(forKey: legacySourceKey) ?? "local").lowercased()
        let decodedSources: [MetadataProviderID]? = {
            guard let json = defaults.string(forKey: sourcesKey),
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([MetadataProviderID].self, from: data)
        }()

        let isOldLocalDefault = picker == "local" &&
            (decodedSources == nil || decodedSources == [.local])
        guard isOldLocalDefault else {
            Logger.shared.log("[MetadataParity] Filza provider repair preserved explicit picker=\\(picker), sources=\\((decodedSources ?? []).map(\\.rawValue).joined(separator: ","))")
            return
        }

        defaults.set("all", forKey: legacySourceKey)
        saveSources(defaultSources)
        Logger.shared.log("[MetadataParity] Repaired embedded default provider state: picker=all, sources=\\(defaultSources.map(\\.rawValue).joined(separator: ","))")
    }
'''
if "filzaMetadataSourcesRepairV2" not in ct:
    ct = replace_once(ct, repair_anchor, repair_code, "metadata provider repair insertion")

selected_anchor = '''    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()
'''
selected_replacement = '''    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()
        repairFilzaEmbeddedDefaultIfNeeded()
'''
ct = replace_once(ct, selected_anchor, selected_replacement, "metadata provider repair call")
compat.write_text(ct)


# ---------------------------------------------------------------------------
# Shared metadata transport repair.
#
# Device logs show CFNetwork/URLSession returning NSURLErrorCannotFindHost for
# music.apple.com, itunes.apple.com and api.deezer.com while the Wi-Fi path is
# satisfied. Keep the upstream background-session path unchanged. Foreground
# metadata requests use an isolated ephemeral URLSession first, then retry only
# DNS-resolution failures through WebKit's separate networking process.
# ---------------------------------------------------------------------------
nt = network.read_text()
nt = replace_once(nt, "import Foundation\n", "import Foundation\nimport WebKit\n", "WebKit import")

transport = r'''
@MainActor
private final class MetadataWebKitRequest: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var finished = false
    private var webView: WKWebView?

    func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.navigationDelegate = self
            webView.load(request)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                guard let self, !self.finished else { return }
                self.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard !finished else { return }
        finished = true
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
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, !self.finished else { return }

            let isHTML = self.response?.mimeType?.lowercased().contains("html") == true
            if isHTML {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !self.finished else { return }
            }

            let script = isHTML
                ? "document.documentElement ? document.documentElement.outerHTML : ''"
                : "document.body ? document.body.innerText : (document.documentElement ? document.documentElement.innerText : '')"

            do {
                let value = try await webView.evaluateJavaScript(script)
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
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

private enum MetadataWebKitTransport {
    @MainActor
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await MetadataWebKitRequest().run(request)
    }
}

enum SongMetadataNetworking {
    @TaskLocal static var useBackgroundSession: Bool = false

    private static func foregroundData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.connectionProxyDictionary = [:]
        return try await URLSession(configuration: configuration).data(for: request)
    }

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
        // Preserve the upstream background-session route exactly. Keeping this
        // direct call avoids moving URLRequest across a helper isolation domain.
        if useBackgroundSession {
            return try await MetadataBackgroundURLSession.shared.data(for: request)
        }

        do {
            return try await foregroundData(for: request)
        } catch {
            guard shouldRetryThroughWebKit(request, error: error) else { throw error }
            let host = request.url?.host ?? "unknown"
            Logger.shared.log("[MetadataNetwork] URLSession DNS failed for \\(host); retrying through WebKit network process")
            do {
                let result = try await MetadataWebKitTransport.data(for: request)
                Logger.shared.log("[MetadataNetwork] WebKit fallback succeeded host=\\(host) bytes=\\(result.0.count)")
                return result
            } catch let fallbackError {
                Logger.shared.log("[MetadataNetwork] WebKit fallback failed host=\\(host): \\(fallbackError)")
                throw error
            }
        }
    }

    static func data(from url: URL) async throws -> (Data, URLResponse) {
        // Preserve upstream background behavior here too rather than wrapping it
        // in a foreground helper.
        if useBackgroundSession {
            return try await MetadataBackgroundURLSession.shared.data(from: url)
        }
        return try await data(for: URLRequest(url: url))
    }
}
'''
nt = replace_braced_block(nt, "enum SongMetadataNetworking {", transport.strip(), "SongMetadataNetworking transport")
network.write_text(nt)
PY

grep -Fq 'filzaMetadataSourcesRepairV2' "$COMPAT"
grep -Fq 'Repaired embedded default provider state' "$COMPAT"
grep -Fq 'import WebKit' "$NETWORK"
grep -Fq 'retrying through WebKit network process' "$NETWORK"
grep -Fq 'URLSessionConfiguration.ephemeral' "$NETWORK"
grep -Fq 'connectionProxyDictionary = [:]' "$NETWORK"
grep -Fq 'MetadataWebKitRequest' "$NETWORK"
grep -Fq 'Preserve the upstream background-session route exactly' "$NETWORK"

echo "Verified ByeTunes metadata provider-state repair and DNS-resilient transport"
