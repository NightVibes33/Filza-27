import Foundation
import SwiftUI

enum MetadataProviderID: String, CaseIterable, Identifiable, Codable {
    case local
    case youtube
    case itunes
    case deezer
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local Files"
        case .youtube: return "YouTube"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        }
    }

    var isRemote: Bool { self != .local }
}

struct MetadataProviderSettings {
    static let sourcesKey = "metadataSourcesJSON"
    static let legacySourceKey = "metadataSource"

    static var defaultSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer, .apple]
    }

    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()

        if UserDefaults.standard.string(forKey: legacySourceKey) == "all" {
            return defaultSources
        }

        guard let json = UserDefaults.standard.string(forKey: sourcesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MetadataProviderID].self, from: data),
              !decoded.isEmpty else {
            return [.local]
        }
        return decoded
    }

    static func saveSources(_ sources: [MetadataProviderID]) {
        let valid = sources.isEmpty ? [MetadataProviderID.local] : sources
        guard let data = try? JSONEncoder().encode(valid),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: sourcesKey)
    }

    static func migrateIfNeeded() {
        guard UserDefaults.standard.string(forKey: sourcesKey) == nil else { return }

        let old = UserDefaults.standard.string(forKey: legacySourceKey) ?? "local"
        let migrated: [MetadataProviderID]
        switch old {
        case "youtube": migrated = [.local, .youtube]
        case "itunes": migrated = [.itunes]
        case "deezer": migrated = [.deezer]
        case "apple": migrated = [.apple]
        case "all": migrated = defaultSources
        default: migrated = [.local]
        }
        saveSources(migrated)
    }
}

struct YouTubeMetadataCandidate: Identifiable, Sendable {
    let videoID: String
    let title: String
    let channelTitle: String
    let description: String?
    let thumbnailURL: URL?
    let durationMs: Int?

    var id: String { videoID }
}

struct PartialSongMetadata: Sendable {
    let title: String
    let artist: String
    let album: String
    let source: MetadataProviderID
}

enum MetadataProvider {
    // These are the same API families used by the pre-v2.4 ByeTunes metadata
    // path. They are metadata-only fallbacks; no YouTube audio is downloaded.
    private static let invidiousInstances = [
        "https://invidious.darkness.services",
        "https://invidious.fdn.fr",
        "https://inv.nadeko.net",
        "https://invidious.jing.rocks",
        "https://invidious.privacydev.net",
        "https://invidious.private.coffee",
        "https://inv.tux.pizza",
        "https://iv.datura.network"
    ]

    private static let pipedInstances = [
        "https://pipedapi.adminforge.de",
        "https://pipedapi.moomoo.me",
        "https://api.piped.projectsegfau.lt",
        "https://api.piped.privacydev.net"
    ]

    static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {
        let cleaned = decodeHTMLEntities(rawTitle)
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Music Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[Official Video]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[Lyrics]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Lyrics)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Visualizer)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(" - ") {
            let parts = cleaned.split(separator: "-", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return PartialSongMetadata(
                title: parts.count > 1 ? parts[1] : cleaned,
                artist: parts.first ?? decodeHTMLEntities(channel),
                album: "YouTube",
                source: .youtube
            )
        }

        return PartialSongMetadata(
            title: cleaned,
            artist: decodeHTMLEntities(channel),
            album: "YouTube",
            source: .youtube
        )
    }

    static func extractYouTubeVideoID(from value: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?(?:[^#]*&)?v=|youtu\.be/|youtube\.com/embed/|music\.youtube\.com/watch\?(?:[^#]*&)?v=)([A-Za-z0-9_-]{11})"#,
            #"^/?watch\?v=([A-Za-z0-9_-]{11})"#,
            #"^/?shorts/([A-Za-z0-9_-]{11})"#,
            #"^/?live/([A-Za-z0-9_-]{11})"#,
            #"^([A-Za-z0-9_-]{11})$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, range: range),
                  let idRange = Range(match.range(at: 1), in: value) else { continue }
            return String(value[idRange])
        }
        return nil
    }

    static func searchYouTubeForMetadata(query: String, limit: Int = 10) async -> [YouTubeMetadataCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let videoID = extractYouTubeVideoID(from: trimmed),
           let direct = await fetchDirectMetadata(videoID: videoID) {
            return [direct]
        }

        for base in invidiousInstances.shuffled() {
            if let results = await searchInvidious(base: base, query: trimmed, limit: limit), !results.isEmpty {
                return results
            }
        }

        for base in pipedInstances.shuffled() {
            if let results = await searchPiped(base: base, query: trimmed, limit: limit), !results.isEmpty {
                return results
            }
        }

        return []
    }

    static func applyYouTubeMatch(_ match: YouTubeMetadataCandidate, to song: SongMetadata) async -> SongMetadata {
        var updated = song
        let normalized = normalizeYouTubeTitle(match.title, channel: match.channelTitle)

        if !normalized.title.isEmpty {
            updated.title = normalized.title
        }
        if !normalized.artist.isEmpty {
            updated.artist = normalized.artist
        }
        if updated.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            updated.album.caseInsensitiveCompare("Unknown Album") == .orderedSame {
            updated.album = normalized.album
        }
        if let durationMs = match.durationMs, durationMs > 0 {
            updated.durationMs = durationMs
        }
        if let thumbnailURL = match.thumbnailURL,
           let data = await fetchData(thumbnailURL, timeout: 5) {
            updated.artworkData = data
            updated.artworkPreviewData = data
        }

        return updated
    }

    static func enrichSongMetadata(_ song: SongMetadata) async -> SongMetadata {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableArtist = artist.caseInsensitiveCompare("Unknown Artist") == .orderedSame ? "" : artist
        let query = [usableArtist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return song }

        let candidates = await searchYouTubeForMetadata(query: query, limit: 8)
        guard !candidates.isEmpty else { return song }

        let best = candidates.max { lhs, rhs in
            matchScore(candidate: lhs, song: song) < matchScore(candidate: rhs, song: song)
        }
        guard let best, matchScore(candidate: best, song: song) >= 0.22 else { return song }
        return await applyYouTubeMatch(best, to: song)
    }

    private static func searchInvidious(base: String, query: String, limit: Int) async -> [YouTubeMetadataCandidate]? {
        guard var components = URLComponents(string: base + "/api/v1/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video")
        ]
        guard let url = components.url,
              let data = await fetchData(url, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: data),
              let items = object as? [[String: Any]] else { return nil }

        var results: [YouTubeMetadataCandidate] = []
        for item in items {
            guard let videoID = item["videoId"] as? String, videoID.count == 11 else { continue }
            let title = item["title"] as? String ?? ""
            let author = item["author"] as? String ?? ""
            guard !title.isEmpty else { continue }

            let durationMs: Int?
            if let seconds = item["lengthSeconds"] as? Int {
                durationMs = seconds * 1000
            } else if let seconds = item["lengthSeconds"] as? NSNumber {
                durationMs = seconds.intValue * 1000
            } else {
                durationMs = nil
            }

            var thumbnailURL: URL?
            if let thumbnails = item["videoThumbnails"] as? [[String: Any]] {
                for thumbnail in thumbnails.reversed() {
                    guard let raw = thumbnail["url"] as? String else { continue }
                    if let absolute = URL(string: raw), absolute.scheme != nil {
                        thumbnailURL = absolute
                    } else if let baseURL = URL(string: base) {
                        thumbnailURL = URL(string: raw, relativeTo: baseURL)?.absoluteURL
                    }
                    if thumbnailURL != nil { break }
                }
            }

            results.append(
                YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: title,
                    channelTitle: author,
                    description: item["description"] as? String,
                    thumbnailURL: thumbnailURL,
                    durationMs: durationMs
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    private static func searchPiped(base: String, query: String, limit: Int) async -> [YouTubeMetadataCandidate]? {
        guard var components = URLComponents(string: base + "/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "filter", value: "videos")
        ]
        guard let url = components.url,
              let data = await fetchData(url, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }

        var results: [YouTubeMetadataCandidate] = []
        for item in items {
            let rawURL = item["url"] as? String ?? ""
            guard let videoID = extractYouTubeVideoID(from: rawURL) else { continue }
            let title = item["title"] as? String ?? ""
            let author = item["uploaderName"] as? String ?? ""
            guard !title.isEmpty else { continue }

            let durationMs: Int?
            if let seconds = item["duration"] as? Int {
                durationMs = seconds * 1000
            } else if let seconds = item["duration"] as? NSNumber {
                durationMs = seconds.intValue * 1000
            } else {
                durationMs = nil
            }

            results.append(
                YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: title,
                    channelTitle: author,
                    description: nil,
                    thumbnailURL: (item["thumbnail"] as? String).flatMap(URL.init(string:)),
                    durationMs: durationMs
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    private static func fetchDirectMetadata(videoID: String) async -> YouTubeMetadataCandidate? {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url,
              let data = await fetchData(url, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let title = json["title"] as? String else { return nil }

        return YouTubeMetadataCandidate(
            videoID: videoID,
            title: title,
            channelTitle: json["author_name"] as? String ?? "",
            description: nil,
            thumbnailURL: (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
            durationMs: nil
        )
    }

    private static func fetchData(_ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func normalizedTokens(_ value: String) -> Set<String> {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let ignored: Set<String> = ["official", "music", "video", "audio", "lyrics", "lyric", "hd", "hq"]
        return Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(max(lhs.count, rhs.count))
    }

    private static func matchScore(candidate: YouTubeMetadataCandidate, song: SongMetadata) -> Double {
        let parsed = normalizeYouTubeTitle(candidate.title, channel: candidate.channelTitle)
        let titleScore = overlap(normalizedTokens(song.title), normalizedTokens(parsed.title))
        let songArtist = normalizedTokens(song.artist)
        let artistScore = overlap(songArtist, normalizedTokens(parsed.artist))
        if songArtist.isEmpty || song.artist.caseInsensitiveCompare("Unknown Artist") == .orderedSame {
            return titleScore
        }
        return (titleScore * 0.72) + (artistScore * 0.28)
    }
}

struct ByeTunesYouTubeMetadataRow: View {
    let match: YouTubeMetadataCandidate

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: match.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(uiColor: .systemGray5)
                    .overlay(Image(systemName: "play.rectangle").foregroundColor(.secondary))
            }
            .frame(width: 48, height: 48)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                Text(match.title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(match.channelTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let durationMs = match.durationMs, durationMs > 0 {
                    Text(Self.durationText(durationMs))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static func durationText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

@MainActor
extension DownloadViewModel {
    func searchAllSourcesCompat(query: String) async {
        await search(query: query, provider: .appleMusic)
        let appleArtists = artistResults
        let appleSongs = songResults
        let appleAlbums = albumResults
        let applePlaylists = playlistResults
        let appleError = errorText

        await search(query: query, provider: .metadata)
        let metadataArtists = artistResults
        let metadataSongs = songResults
        let metadataAlbums = albumResults
        let metadataPlaylists = playlistResults
        let metadataError = errorText

        artistResults = Self.mergeUnique(appleArtists, metadataArtists)
        songResults = Self.mergeUnique(appleSongs, metadataSongs)
        albumResults = Self.mergeUnique(appleAlbums, metadataAlbums)
        playlistResults = Self.mergeUnique(applePlaylists, metadataPlaylists)

        canLoadMoreSongs = false
        canLoadMoreAlbums = false
        canLoadMorePlaylists = false

        if artistResults.isEmpty && songResults.isEmpty && albumResults.isEmpty && playlistResults.isEmpty {
            errorText = [appleError, metadataError]
                .compactMap { $0 }
                .first ?? "No results found across available sources."
        } else {
            errorText = nil
        }
    }

    private static func mergeUnique<T: Identifiable>(_ first: [T], _ second: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        var merged: [T] = []
        for item in first + second where seen.insert(item.id).inserted {
            merged.append(item)
        }
        return merged
    }
}
