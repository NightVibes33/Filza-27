import Foundation
import Security
import SwiftUI
import UIKit
import WebKit

enum AppleMusicSyncedLyricsCredentialStore {
    private static let service = "com.nightvibes33.filza27.byetunes.applemusic"
    private static let userTokenAccount = "media-user-token"
    private static let storefrontAccount = "storefront"

    private struct ProtectedCredential: Codable {
        let userToken: String
        let storefront: String?
    }

    static var isConnected: Bool {
        guard let token = userToken else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var userToken: String? {
        if let token = loadKeychain(account: userTokenAccount),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        return loadProtectedFallback()?.userToken
    }

    static var storefront: String? {
        if let storefront = loadKeychain(account: storefrontAccount),
           !storefront.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storefront
        }
        return loadProtectedFallback()?.storefront
    }

    @discardableResult
    static func save(userToken: String, storefront: String?) -> Bool {
        let token = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }

        let normalizedStorefront = storefront?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let tokenKeychainSaved = saveKeychain(value: token, account: userTokenAccount)
        var storefrontKeychainSaved = true
        if let normalizedStorefront, !normalizedStorefront.isEmpty {
            storefrontKeychainSaved = saveKeychain(
                value: normalizedStorefront,
                account: storefrontAccount
            )
        }

        let fallbackSaved = saveProtectedFallback(
            ProtectedCredential(
                userToken: token,
                storefront: normalizedStorefront?.isEmpty == false ? normalizedStorefront : nil
            )
        )

        guard tokenKeychainSaved || fallbackSaved else {
            Logger.shared.log("[AppleLyrics] credential persistence failed")
            return false
        }

        guard let persistedToken = self.userToken,
              persistedToken == token else {
            Logger.shared.log("[AppleLyrics] credential read-back verification failed")
            return false
        }

        if let normalizedStorefront, !normalizedStorefront.isEmpty,
           self.storefront != normalizedStorefront {
            Logger.shared.log("[AppleLyrics] storefront read-back verification failed")
            return false
        }

        if !tokenKeychainSaved || !storefrontKeychainSaved {
            Logger.shared.log("[AppleLyrics] Keychain unavailable; protected credential-file fallback active")
        } else {
            Logger.shared.log("[AppleLyrics] credential persistence verified in Keychain")
        }
        return true
    }

    @discardableResult
    static func save(storefront: String) -> Bool {
        let normalized = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let keychainSaved = saveKeychain(value: normalized, account: storefrontAccount)
        if let token = userToken {
            _ = saveProtectedFallback(
                ProtectedCredential(userToken: token, storefront: normalized)
            )
        }
        return keychainSaved || self.storefront == normalized
    }

    static func clear() {
        deleteKeychain(account: userTokenAccount)
        deleteKeychain(account: storefrontAccount)
        if let url = protectedFallbackURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func loadKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func saveKeychain(value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus != errSecItemNotFound {
            Logger.shared.log("[AppleLyrics] Keychain update failed status=\(updateStatus)")
        }

        var insert = key
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus != errSecSuccess {
            Logger.shared.log("[AppleLyrics] Keychain insert failed status=\(insertStatus)")
        }
        return insertStatus == errSecSuccess
    }

    private static func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static var protectedFallbackURL: URL? {
        let base =
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: DeviceManager.appGroupID
            ) ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        guard let base else { return nil }
        let directory = base.appendingPathComponent(".byetunes-credentials", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return directory.appendingPathComponent("apple-music.json")
        } catch {
            Logger.shared.log("[AppleLyrics] protected credential directory unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saveProtectedFallback(_ credential: ProtectedCredential) -> Bool {
        guard let url = protectedFallbackURL,
              let data = try? JSONEncoder().encode(credential) else {
            return false
        }

        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            Logger.shared.log("[AppleLyrics] protected credential fallback write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func loadProtectedFallback() -> ProtectedCredential? {
        guard let url = protectedFallbackURL,
              let data = try? Data(contentsOf: url),
              let credential = try? JSONDecoder().decode(ProtectedCredential.self, from: data),
              !credential.userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return credential
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

    func validateStoredCredentials() async -> Bool {
        guard let userToken = AppleMusicSyncedLyricsCredentialStore.userToken,
              !userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard let developerToken = await developerToken() else {
            Logger.shared.log("[AppleLyrics] developer token unavailable; keeping saved Apple Music login")
            return true
        }

        if let storefront = await validatedStorefront(
            developerToken: developerToken,
            userToken: userToken
        ) {
            _ = AppleMusicSyncedLyricsCredentialStore.save(
                userToken: userToken,
                storefront: storefront
            )
        } else {
            Logger.shared.log("[AppleLyrics] storefront validation deferred; keeping saved Apple Music login")
        }
        return true
    }

    func validateAndPersistUserToken(_ rawToken: String) async -> Bool {
        let token = (rawToken.removingPercentEncoding ?? rawToken)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }

        guard let developerToken = await developerToken() else {
            Logger.shared.log("[AppleLyrics] cannot validate user token because developer token is unavailable")
            return false
        }

        guard let storefront = await validatedStorefront(
            developerToken: developerToken,
            userToken: token
        ) else {
            Logger.shared.log("[AppleLyrics] Apple rejected captured media-user-token")
            return false
        }

        guard AppleMusicSyncedLyricsCredentialStore.save(
            userToken: token,
            storefront: storefront
        ) else {
            return false
        }

        Logger.shared.log("[AppleLyrics] Apple Music token validated and persisted for storefront \(storefront)")
        return true
    }

    private func validatedStorefront(
        developerToken: String,
        userToken: String
    ) async -> String? {
        guard let url = URL(string: "\(apiRoot)/v1/me/storefront") else { return nil }
        var request = URLRequest(url: url)
        addCommonHeaders(to: &request, developerToken: developerToken)
        request.setValue(userToken, forHTTPHeaderField: "Media-User-Token")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = (root["data"] as? [[String: Any]])?.first,
                  let storefront = item["id"] as? String,
                  !storefront.isEmpty else {
                Logger.shared.log("[AppleLyrics] credential validation failed HTTP \(status)")
                return nil
            }
            return storefront.lowercased()
        } catch {
            Logger.shared.log("[AppleLyrics] credential validation request failed: \(error.localizedDescription)")
            return nil
        }
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

        if let storefront = await validatedStorefront(
            developerToken: developerToken,
            userToken: userToken
        ) {
            _ = AppleMusicSyncedLyricsCredentialStore.save(storefront: storefront)
            return storefront
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
                connected = success
                if success {
                    UserDefaults.standard.set(true, forKey: "appleSubscriptionLyrics")
                }
            }
        }
        .task {
            connected = await AppleMusicSyncedLyricsClient.shared.validateStoredCredentials()
        }
    }
}

struct AppleMusicSyncedLyricsBootstrapView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Never force Apple authentication when ByeTunes opens.
        // Sign-in is user initiated from the Apple Music Lyrics connection row
        // or when Apple Music Synced is explicitly selected in the lyric picker.
        content
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
    private var tokenFirstSeenAt: Date?
    private static let storefrontGrace: TimeInterval = 8

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
        let dataStore = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { [weak self] records in
            guard let self else { return }
            let appleRecords = records.filter {
                $0.displayName.contains("apple.com") || $0.displayName.contains("icloud.com")
            }

            let loadLogin: @MainActor () -> Void = {
                guard let url = URL(string: "https://music.apple.com/login") else { return }
                self.webView.load(URLRequest(url: url))
                self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.pollCookies()
                    }
                }
            }

            guard !appleRecords.isEmpty else {
                Task { @MainActor in loadLogin() }
                return
            }

            dataStore.removeData(ofTypes: types, for: appleRecords) {
                Task { @MainActor in loadLogin() }
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
                guard let tokenCookie = cookies.first(where: { $0.name == "media-user-token" }),
                      !tokenCookie.value.isEmpty else {
                    return
                }

                let storefront = cookies.first(where: { $0.name == "itua" })?.value
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let storefront, !storefront.isEmpty {
                    self.finishLogin(token: tokenCookie.value, storefront: storefront.lowercased())
                    return
                }

                if self.tokenFirstSeenAt == nil {
                    self.tokenFirstSeenAt = Date()
                    Logger.shared.log("[AppleLyrics] media-user-token captured; waiting briefly for storefront")
                    return
                }

                guard let firstSeen = self.tokenFirstSeenAt,
                      Date().timeIntervalSince(firstSeen) >= Self.storefrontGrace else {
                    return
                }

                self.finishLogin(token: tokenCookie.value, storefront: nil)
            }
        }
    }

    private func finishLogin(token rawToken: String, storefront: String?) {
        guard !completed else { return }
        let token = (rawToken.removingPercentEncoding ?? rawToken)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        completed = true
        pollTimer?.invalidate()
        pollTimer = nil

        let saved = AppleMusicSyncedLyricsCredentialStore.save(
            userToken: token,
            storefront: storefront
        )

        if saved {
            Logger.shared.log("[AppleLyrics] Apple Music user token captured and persisted")
        } else {
            Logger.shared.log("[AppleLyrics] Apple Music token capture succeeded but persistence failed")
        }
        completion(saved)
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
