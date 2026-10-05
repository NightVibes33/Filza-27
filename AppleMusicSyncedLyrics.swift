import Foundation
import Security
import SwiftUI
import UIKit
import WebKit

enum AppleMusicSyncedLyricsCredentialStore {
    private static let service = "com.nightvibes33.filza27.byetunes.applemusic"
    private static let userTokenAccount = "media-user-token"
    private static let storefrontAccount = "storefront"

    static var isConnected: Bool {
        guard let token = load(account: userTokenAccount) else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var userToken: String? {
        load(account: userTokenAccount)
    }

    static var storefront: String? {
        load(account: storefrontAccount)
    }

    static func save(userToken: String, storefront: String?) {
        save(value: userToken, account: userTokenAccount)
        if let storefront {
            let trimmed = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                save(value: trimmed, account: storefrontAccount)
            }
        }
    }

    static func save(storefront: String) {
        let trimmed = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        save(value: trimmed, account: storefrontAccount)
    }

    static func clear() {
        delete(account: userTokenAccount)
        delete(account: storefrontAccount)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func save(value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = key
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AppleMusicSyncedLyricsAccessCache {
    private static let key = "filzaByeTunesAppleSyncedLyricsConfirmedIDs"

    static func contains(songID: String) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(songID)
    }

    static func markAvailable(songID: String) {
        var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        values.insert(songID)
        if values.count > 500 {
            values = Set(values.suffix(500))
        }
        UserDefaults.standard.set(Array(values), forKey: key)
    }
}

@MainActor
final class AppleMusicSyncedLyricsClient {
    static let shared = AppleMusicSyncedLyricsClient()

    private let webOrigin = "https://music.apple.com"
    private let apiRoot = "https://amp-api.music.apple.com"
    private let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
    private let developerTokenKey = "filzaByeTunesAppleMusicDeveloperToken"
    private let developerTokenExpiryKey = "filzaByeTunesAppleMusicDeveloperTokenExpiry"

    private init() {}

    func hasTimeSyncedLyrics(songID: String, storefront: String? = nil) async -> Bool {
        guard let developerToken = await developerToken() else { return false }
        let region = normalizedStorefront(storefront)
        guard let url = URL(string: "\(apiRoot)/v1/catalog/\(region)/songs/\(songID)") else { return false }
        var request = URLRequest(url: url)
        addCommonHeaders(to: &request, developerToken: developerToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = (root["data"] as? [[String: Any]])?.first,
                  let attributes = item["attributes"] as? [String: Any] else {
                return false
            }
            return attributes["hasTimeSyncedLyrics"] as? Bool ?? false
        } catch {
            Logger.shared.log("[AppleLyrics] availability lookup failed for \(songID): \(error)")
            return false
        }
    }

    func fetchSyncedLyrics(songID: String, storefront: String? = nil) async -> String? {
        guard let userToken = AppleMusicSyncedLyricsCredentialStore.userToken,
              !userToken.isEmpty else {
            Logger.shared.log("[AppleLyrics] Apple Music sign-in required")
            return nil
        }
        guard let developerToken = await developerToken() else {
            Logger.shared.log("[AppleLyrics] could not obtain Apple web developer token")
            return nil
        }

        let region = await resolvedStorefront(
            preferred: storefront,
            developerToken: developerToken,
            userToken: userToken
        )

        for kind in ["syllable-lyrics", "lyrics"] {
            guard let url = URL(string: "\(apiRoot)/v1/catalog/\(region)/songs/\(songID)/\(kind)?extend=ttmlLocalizations") else {
                continue
            }
            var request = URLRequest(url: url)
            addCommonHeaders(to: &request, developerToken: developerToken)
            request.setValue(userToken, forHTTPHeaderField: "Media-User-Token")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 401 || status == 403 {
                    Logger.shared.log("[AppleLyrics] media-user-token rejected; reconnect Apple Music")
                    AppleMusicSyncedLyricsCredentialStore.clear()
                    return nil
                }
                if status == 404 {
                    continue
                }
                guard status == 200,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let item = (root["data"] as? [[String: Any]])?.first,
                      let attributes = item["attributes"] as? [String: Any] else {
                    continue
                }

                let ttml =
                    (attributes["ttmlLocalizations"] as? String) ??
                    (attributes["ttml"] as? String) ??
                    ""
                guard !ttml.isEmpty,
                      let lrc = TTMLLyricsParser.parse(ttml),
                      !lrc.isEmpty else {
                    continue
                }

                AppleMusicSyncedLyricsAccessCache.markAvailable(songID: songID)
                Logger.shared.log("[AppleLyrics] loaded Apple \(kind) TTML for \(songID)")
                return lrc
            } catch {
                Logger.shared.log("[AppleLyrics] request failed for \(songID): \(error)")
            }
        }

        return nil
    }

    private func resolvedStorefront(
        preferred: String?,
        developerToken: String,
        userToken: String
    ) async -> String {
        if let saved = AppleMusicSyncedLyricsCredentialStore.storefront,
           !saved.isEmpty {
            return saved
        }

        if let url = URL(string: "\(apiRoot)/v1/me/storefront") {
            var request = URLRequest(url: url)
            addCommonHeaders(to: &request, developerToken: developerToken)
            request.setValue(userToken, forHTTPHeaderField: "Media-User-Token")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let item = (root["data"] as? [[String: Any]])?.first,
               let storefront = item["id"] as? String,
               !storefront.isEmpty {
                AppleMusicSyncedLyricsCredentialStore.save(storefront: storefront)
                return storefront.lowercased()
            }
        }

        return normalizedStorefront(preferred)
    }

    private func normalizedStorefront(_ preferred: String?) -> String {
        let candidate =
            preferred ??
            AppleMusicSyncedLyricsCredentialStore.storefront ??
            UserDefaults.standard.string(forKey: "storeRegion") ??
            "US"
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "us" : trimmed
    }

    private func addCommonHeaders(to request: inout URLRequest, developerToken: String) {
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(webOrigin, forHTTPHeaderField: "Origin")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func developerToken() async -> String? {
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: developerTokenKey),
           !cached.isEmpty,
           defaults.double(forKey: developerTokenExpiryKey) > Date().addingTimeInterval(3600).timeIntervalSince1970 {
            return cached
        }

        let landingPages = [
            "https://music.apple.com/us/browse",
            "https://music.apple.com/"
        ]

        for landing in landingPages {
            guard let landingURL = URL(string: landing) else { continue }
            var request = URLRequest(url: landingURL)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let html = String(data: data, encoding: .utf8) else {
                continue
            }

            let assets = javascriptAssetURLs(from: html, baseURL: landingURL)
            var candidates: [(token: String, expiry: Date)] = []

            for assetURL in assets.prefix(8) {
                var assetRequest = URLRequest(url: assetURL)
                assetRequest.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
                guard let (assetData, _) = try? await URLSession.shared.data(for: assetRequest),
                      let source = String(data: assetData, encoding: .utf8) else {
                    continue
                }

                for token in jwtCandidates(from: source) {
                    guard let expiry = jwtExpiry(token), expiry > Date().addingTimeInterval(3600) else { continue }
                    candidates.append((token, expiry))
                }
            }

            let ordered = Dictionary(grouping: candidates, by: { $0.token })
                .compactMap { $0.value.max(by: { $0.expiry < $1.expiry }) }
                .sorted { $0.expiry > $1.expiry }

            for candidate in ordered.prefix(12) {
                if await validateDeveloperToken(candidate.token) {
                    defaults.set(candidate.token, forKey: developerTokenKey)
                    defaults.set(candidate.expiry.timeIntervalSince1970, forKey: developerTokenExpiryKey)
                    Logger.shared.log("[AppleLyrics] refreshed Apple web developer token")
                    return candidate.token
                }
            }
        }

        return nil
    }

    private func validateDeveloperToken(_ token: String) async -> Bool {
        guard let url = URL(string: "\(apiRoot)/v1/catalog/us/search?types=songs&term=music&limit=1") else {
            return false
        }
        var request = URLRequest(url: url)
        addCommonHeaders(to: &request, developerToken: token)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func javascriptAssetURLs(from html: String, baseURL: URL) -> [URL] {
        let patterns = [
            #"<script[^>]+src=["']([^"']+\.js(?:\?[^"']*)?)["']"#,
            #"(/assets/[A-Za-z0-9._~/-]+\.js)"#
        ]
        var seen = Set<String>()
        var urls: [URL] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                let index = match.numberOfRanges > 1 ? 1 : 0
                guard let swiftRange = Range(match.range(at: index), in: html) else { continue }
                let raw = String(html[swiftRange])
                guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                      seen.insert(url.absoluteString).inserted else {
                    continue
                }
                urls.append(url)
            }
        }
        return urls
    }

    private func jwtCandidates(from source: String) -> [String] {
        let pattern = #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

private final class TTMLLyricsParser: NSObject, XMLParserDelegate {
    private struct Word {
        let start: TimeInterval
        let text: String
    }

    private struct Line {
        let start: TimeInterval
        let text: String
        let words: [Word]
    }

    private var lines: [Line] = []
    private var lineStart: TimeInterval?
    private var lineText = ""
    private var words: [Word] = []
    private var spanStart: TimeInterval?
    private var spanText = ""
    private var insideParagraph = false
    private var insideSpan = false

    static func parse(_ ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let collector = TTMLLyricsParser()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        let rendered = collector.lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let lineStamp = format(line.start, opening: "[", closing: "]")
            if line.words.isEmpty {
                return lineStamp + text
            }
            let enhanced = line.words.map { word in
                format(word.start, opening: "<", closing: ">") + word.text
            }.joined()
            return lineStamp + enhanced
        }.joined(separator: "\n")
        return rendered.isEmpty ? nil : rendered
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "p" {
            insideParagraph = true
            lineStart = Self.parseTime(attributeDict["begin"])
            lineText = ""
            words = []
        } else if name == "span", insideParagraph {
            insideSpan = true
            spanStart = Self.parseTime(attributeDict["begin"])
            spanText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideParagraph else { return }
        lineText += string
        if insideSpan {
            spanText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "span", insideParagraph {
            if let spanStart {
                words.append(Word(start: spanStart, text: spanText))
            }
            insideSpan = false
            spanStart = nil
            spanText = ""
        } else if name == "p", insideParagraph {
            let start = lineStart ?? words.first?.start ?? 0
            lines.append(Line(start: start, text: lineText, words: words))
            insideParagraph = false
            lineStart = nil
            lineText = ""
            words = []
        }
    }

    private static func parseTime(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("s"), let seconds = Double(trimmed.dropLast()) {
            return seconds
        }

        let parts = trimmed.split(separator: ":")
        if parts.count == 3,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]) {
            return hours * 3600 + minutes * 60 + seconds
        }
        if parts.count == 2,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]) {
            return minutes * 60 + seconds
        }
        return Double(trimmed)
    }

    private static func format(_ time: TimeInterval, opening: String, closing: String) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped / 60)
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%@%02d:%05.2f%@", opening, minutes, seconds, closing)
    }
}

struct AppleMusicSyncedLyricsAvailabilityBadge: View {
    let songID: String
    @State private var hasSyncedLyrics = false

    var body: some View {
        Group {
            if hasSyncedLyrics {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("Apple Music synced lyrics available")
            }
        }
        .task(id: songID) {
            hasSyncedLyrics = await AppleMusicSyncedLyricsClient.shared.hasTimeSyncedLyrics(songID: songID)
        }
    }
}

struct AppleMusicSyncedLyricsConnectionRow: View {
    @State private var showingLogin = false
    @State private var connected = AppleMusicSyncedLyricsCredentialStore.isConnected

    var body: some View {
        HStack {
            Image(systemName: connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music Lyrics")
                Text(connected ? "Connected for Apple synced lyrics." : "Sign in once; no token copying required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(connected ? "Reconnect" : "Connect") {
                if connected {
                    AppleMusicSyncedLyricsCredentialStore.clear()
                }
                showingLogin = true
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .sheet(isPresented: $showingLogin) {
            AppleMusicSyncedLyricsLoginSheet { success in
                connected = success || AppleMusicSyncedLyricsCredentialStore.isConnected
                if success {
                    UserDefaults.standard.set(true, forKey: "appleSubscriptionLyrics")
                }
            }
        }
    }
}

struct AppleMusicSyncedLyricsBootstrapView<Content: View>: View {
    private let content: Content
    @State private var showingLogin = false
    @State private var didPrompt = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                guard !didPrompt else { return }
                didPrompt = true
                guard !AppleMusicSyncedLyricsCredentialStore.isConnected else {
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showingLogin = true
                }
            }
            .sheet(isPresented: $showingLogin) {
                AppleMusicSyncedLyricsLoginSheet { success in
                    if success {
                        UserDefaults.standard.set(true, forKey: "appleSubscriptionLyrics")
                        Logger.shared.log("[AppleLyrics] Apple-first synced lyrics enabled after sign-in")
                    }
                }
            }
    }
}

struct AppleMusicSyncedLyricsLoginSheet: View {
    let onComplete: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppleMusicSyncedLyricsLoginWebView { success in
                onComplete(success)
                dismiss()
            }
            .navigationTitle("Connect Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onComplete(false)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AppleMusicSyncedLyricsLoginWebView: UIViewControllerRepresentable {
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        AppleMusicSyncedLyricsLoginViewController(completion: completion)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

@MainActor
private final class AppleMusicSyncedLyricsLoginViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let completion: (Bool) -> Void
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var completed = false

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        prepareFreshLogin()
    }

    private func prepareFreshLogin() {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let appleCookies = cookies.filter { cookie in
                cookie.domain.contains("apple.com") || cookie.domain.contains("icloud.com")
            }

            let group = DispatchGroup()
            for cookie in appleCookies {
                group.enter()
                cookieStore.delete(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                guard let url = URL(string: "https://music.apple.com/login") else { return }
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                self.webView.load(request)
                self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.pollCookies()
                    }
                }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func pollCookies() {
        guard !completed else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.completed else { return }
                guard let token = cookies.first(where: { $0.name == "media-user-token" })?.value,
                      !token.isEmpty else {
                    return
                }
                let storefront = cookies.first(where: { $0.name == "itua" })?.value
                AppleMusicSyncedLyricsCredentialStore.save(userToken: token, storefront: storefront)
                self.completed = true
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                Logger.shared.log("[AppleLyrics] captured Apple Music user token locally")
                self.completion(true)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
