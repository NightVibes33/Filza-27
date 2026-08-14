#!/bin/bash
set -euo pipefail

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MUSIC="ByeTunes/MusicManager/MusicView.swift"
SONG="ByeTunes/MusicManager/SongMetadata.swift"
COMPAT="ByeTunesMetadataCompat.swift"

for path in "$SETTINGS" "$MUSIC" "$SONG" "$COMPAT"; do
    test -f "$path"
done

python3 - "$SETTINGS" "$MUSIC" "$SONG" "$COMPAT" <<'PY'
from pathlib import Path
import sys

settings = Path(sys.argv[1])
music = Path(sys.argv[2])
song = Path(sys.argv[3])
compat = Path(sys.argv[4])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def replace_braced_function(text: str, signature: str, replacement: str, label: str) -> str:
    start = text.find(signature)
    if start < 0:
        if replacement in text:
            return text
        raise SystemExit(f"{label}: signature not found")
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
# Settings parity
# ---------------------------------------------------------------------------
ss = settings.read_text()
old_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metadataSource) { newValue in
            persistMetadataSelection(newValue)
        }
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
            MetadataProviderSettings.migrateIfNeeded()
            persistMetadataSelection(metadataSource)
        }
'''
new_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metadataSource) { newValue in
            persistMetadataSelection(newValue)
        }
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
        }
'''
ss = replace_once(ss, old_modifiers, new_modifiers, "metadata settings open-state parity")

ss = replace_once(
    ss,
    '                        if metadataSource == "itunes" || metadataSource == "all" {\n',
    '                        if metadataSource == "itunes" || metadataSource == "apple" || metadataSource == "all" {\n',
    "Store Region visibility parity",
)
settings.write_text(ss)


# ---------------------------------------------------------------------------
# SongMetadata provenance fields removed by v2.4
# ---------------------------------------------------------------------------
sms = song.read_text()
anchor = '''    var richAppleMetadataFetched: Bool = false
'''
addition = '''    var richAppleMetadataFetched: Bool = false
    var youtubeVideoID: String? = nil
    var metadataSourcesUsed: [MetadataProviderID] = []
'''
sms = replace_once(sms, anchor, addition, "SongMetadata provider provenance fields")
song.write_text(sms)


# ---------------------------------------------------------------------------
# YouTube provider behavior parity.
#
# Pre-v2.4 used YouTubeKit first, then public Invidious/Piped/HTML/noembed
# fallbacks. YouTubeKit is no longer present in the pinned v2.4 SwiftPM graph
# used by this raw Theos embed, so keep the original public-fallback order and
# first-result semantics. Do not introduce a custom score/threshold policy.
# ---------------------------------------------------------------------------
ct = compat.read_text()

original_normalizer = '''    static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {
        let cleaned = rawTitle
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[Lyrics]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Lyrics)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Visualizer)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(AMV)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Remix)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Unreleased)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Leak)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "prod.", with: "prod.", options: .caseInsensitive)
            .replacingOccurrences(of: "ft.", with: "feat.", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(" - ") {
            let parts = cleaned.split(separator: "-", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return PartialSongMetadata(
                title: parts.count > 1 ? parts[1] : cleaned,
                artist: parts.first ?? channel,
                album: "YouTube",
                source: .youtube
            )
        }
        return PartialSongMetadata(
            title: cleaned,
            artist: channel,
            album: "YouTube",
            source: .youtube
        )
    }'''
ct = replace_braced_function(
    ct,
    "    static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {",
    original_normalizer,
    "YouTube title normalizer parity",
)

# Restore the original first-result search contract. searchInvidious/searchPiped
# remain transport helpers; no ranking is applied after they return.
original_search = '''    static func searchYouTubeForMetadata(query: String, limit: Int = 5) async -> [YouTubeMetadataCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

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

        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let searchURL = URL(string: "https://www.youtube.com/results?search_query=\\(encodedQuery)") else {
            return []
        }

        do {
            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }

            var videoIDs: [String] = []
            let patterns = [
                #"\"videoId\":\"([a-zA-Z0-9_-]{11})\""#,
                #"watch\\?v=([a-zA-Z0-9_-]{11})"#,
                #"/watch\\?v=([a-zA-Z0-9_-]{11})"#,
                #"\"videoIds\":\"([a-zA-Z0-9_-]{11})\""#,
                #"%22videoId%22%3A%22([a-zA-Z0-9_-]{11})%22"#,
                #"\\\"videoId\\\":\\\"([a-zA-Z0-9_-]{11})\\\""#,
                #"videoId%22%3A%22([a-zA-Z0-9_-]{11})"#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    if let range = Range(match.range(at: 1), in: html) {
                        let videoID = String(html[range])
                        if !videoIDs.contains(videoID) { videoIDs.append(videoID) }
                    }
                }
            }

            var candidates: [YouTubeMetadataCandidate] = []
            for videoID in videoIDs.prefix(limit) {
                if let candidate = await fetchYouTubeMetadata(videoID: videoID) {
                    candidates.append(candidate)
                }
            }
            return candidates
        } catch {
            Logger.shared.log("[YouTubeProvider] YouTube HTML search failed: \\(error)")
            return []
        }
    }'''
ct = replace_braced_function(
    ct,
    "    static func searchYouTubeForMetadata(query: String, limit: Int = 10) async -> [YouTubeMetadataCandidate] {",
    original_search,
    "YouTube search parity",
)

# Piped's old API contract returned a top-level array. Accept that first, while
# tolerating the newer {items:[...]} shape so a public instance format change
# does not make the restored provider unusable.
original_piped = '''    private static func searchPiped(base: String, query: String, limit: Int) async -> [YouTubeMetadataCandidate]? {
        guard var components = URLComponents(string: base + "/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "filter", value: "videos")
        ]
        guard let url = components.url,
              let data = await fetchData(url, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let root = object as? [String: Any],
                  let array = root["items"] as? [[String: Any]] {
            items = array
        } else {
            return nil
        }

        var results: [YouTubeMetadataCandidate] = []
        for item in items.prefix(limit) {
            let rawURL = item["url"] as? String ?? ""
            guard let videoID = extractYouTubeVideoID(from: rawURL) else { continue }
            let title = item["title"] as? String ?? item["name"] as? String ?? ""
            let uploader = item["uploaderName"] as? String ?? item["uploader"] as? String ?? ""
            let duration: Int?
            if let value = item["duration"] as? Int { duration = value }
            else if let value = item["duration"] as? NSNumber { duration = value.intValue }
            else { duration = nil }

            if !title.isEmpty || !uploader.isEmpty {
                results.append(
                    YouTubeMetadataCandidate(
                        videoID: videoID,
                        title: title,
                        channelTitle: uploader,
                        description: nil,
                        thumbnailURL: (item["thumbnail"] as? String).flatMap(URL.init(string:)),
                        durationMs: duration.map { $0 * 1000 }
                    )
                )
            }
        }
        return results
    }'''
ct = replace_braced_function(
    ct,
    "    private static func searchPiped(base: String, query: String, limit: Int) async -> [YouTubeMetadataCandidate]? {",
    original_piped,
    "Piped result-shape parity",
)

# Public direct-ID route used by the original MusicView. Preserve the old
# Invidious -> Piped -> noembed fallback ordering (minus removed YouTubeKit).
fetch_direct = '''    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil) async -> YouTubeMetadataCandidate? {
        if let apiKey, !apiKey.isEmpty,
           var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos") {
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: videoID),
                URLQueryItem(name: "key", value: apiKey)
            ]
            if let url = components.url,
               let data = await fetchData(url, timeout: 8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let root = object as? [String: Any],
               let items = root["items"] as? [[String: Any]],
               let first = items.first {
                let snippet = first["snippet"] as? [String: Any] ?? [:]
                let details = first["contentDetails"] as? [String: Any] ?? [:]
                let thumbnails = snippet["thumbnails"] as? [String: Any]
                let high = thumbnails?["high"] as? [String: Any]
                let fallback = thumbnails?["default"] as? [String: Any]
                let duration = (details["duration"] as? String).flatMap(parseISO8601Duration)
                return YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: snippet["title"] as? String ?? "",
                    channelTitle: snippet["channelTitle"] as? String ?? "",
                    description: snippet["description"] as? String,
                    thumbnailURL: ((high?["url"] as? String) ?? (fallback?["url"] as? String)).flatMap(URL.init(string:)),
                    durationMs: duration
                )
            }
        }

        for base in invidiousInstances.shuffled() {
            guard let url = URL(string: base + "/api/v1/videos/" + videoID),
                  let data = await fetchData(url, timeout: 5),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else { continue }

            let title = json["title"] as? String ?? ""
            let author = json["author"] as? String ?? ""
            guard !title.isEmpty || !author.isEmpty else { continue }
            let seconds = (json["lengthSeconds"] as? Int) ?? (json["lengthSeconds"] as? NSNumber)?.intValue
            var thumbnailURL: URL?
            if let thumbs = json["videoThumbnails"] as? [[String: Any]] {
                let preferred = thumbs.first { ($0["quality"] as? String) == "maxresdefault" }
                    ?? thumbs.first { ($0["quality"] as? String) == "high" }
                    ?? thumbs.first { ($0["quality"] as? String) == "medium" }
                    ?? thumbs.first
                thumbnailURL = (preferred?["url"] as? String).flatMap(URL.init(string:))
            }
            return YouTubeMetadataCandidate(
                videoID: videoID,
                title: title,
                channelTitle: author,
                description: json["description"] as? String,
                thumbnailURL: thumbnailURL,
                durationMs: seconds.map { $0 * 1000 }
            )
        }

        for base in pipedInstances.shuffled() {
            guard let url = URL(string: base + "/streams/" + videoID),
                  let data = await fetchData(url, timeout: 5),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else { continue }
            let title = json["title"] as? String ?? ""
            let uploader = json["uploader"] as? String ?? ""
            guard !title.isEmpty || !uploader.isEmpty else { continue }
            let duration = (json["duration"] as? Int) ?? (json["duration"] as? NSNumber)?.intValue
            return YouTubeMetadataCandidate(
                videoID: videoID,
                title: title,
                channelTitle: uploader,
                description: json["description"] as? String,
                thumbnailURL: (json["thumbnailUrl"] as? String).flatMap(URL.init(string:)),
                durationMs: duration.map { $0 * 1000 }
            )
        }

        guard let url = URL(string: "https://noembed.com/embed?url=https://www.youtube.com/watch?v=" + videoID),
              let data = await fetchData(url, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }
        let title = json["title"] as? String ?? ""
        let author = json["author_name"] as? String ?? ""
        guard !title.isEmpty || !author.isEmpty else { return nil }
        return YouTubeMetadataCandidate(
            videoID: videoID,
            title: title,
            channelTitle: author,
            description: nil,
            thumbnailURL: (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
            durationMs: nil
        )
    }

    private static func parseISO8601Duration(_ duration: String) -> Int? {
        let pattern = #"PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = duration as NSString
        guard let match = regex.firstMatch(in: duration, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var total = 0
        if let range = Range(match.range(at: 1), in: duration), let hours = Int(duration[range]) { total += hours * 3_600_000 }
        if let range = Range(match.range(at: 2), in: duration), let minutes = Int(duration[range]) { total += minutes * 60_000 }
        if let range = Range(match.range(at: 3), in: duration), let seconds = Int(duration[range]) { total += seconds * 1_000 }
        return total > 0 ? total : nil
    }
'''
insert_anchor = "    private static func fetchDirectMetadata(videoID: String) async -> YouTubeMetadataCandidate? {"
start = ct.find(insert_anchor)
if start < 0:
    if "    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil)" not in ct:
        raise SystemExit("direct YouTube metadata helper anchor not found")
else:
    # Remove the compatibility-only oEmbed helper and replace it with the old
    # public direct-ID contract plus duration parser.
    ct = replace_braced_function(ct, insert_anchor, fetch_direct.rstrip(), "direct YouTube metadata parity")

# Custom score helpers are no longer part of import selection. They may remain
# private for binary compatibility, but the import pipeline below must not call
# enrichSongMetadata or matchScore.
compat.write_text(ct)


# ---------------------------------------------------------------------------
# MusicView import behavior: exact old source order and YouTube first-result
# semantics, including filename video-ID recognition before search.
# ---------------------------------------------------------------------------
ms = music.read_text()
loop_anchor = '''            if autofetch {
                let sources = MetadataProviderSettings.selectedSources()
                Logger.shared.log("[MusicView] Filza embed metadata compatibility sources=\\(sources.map(\\.rawValue).joined(separator: ","))")
                for source in sources {
'''
loop_replacement = '''            var sourcesUsed: [MetadataProviderID] = [.local]
            if autofetch {
                let sources = MetadataProviderSettings.selectedSources()
                Logger.shared.log("[MusicView] metadata sources=\\(sources.map(\\.rawValue).joined(separator: ","))")
                for source in sources {
'''
ms = replace_once(ms, loop_anchor, loop_replacement, "MusicView provider provenance start")

old_cases = '''                    case .local:
                        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                            song = await SongMetadata.matchAppleMusicMetadata(song)
                        }
                    case .youtube:
                        song = await MetadataProvider.enrichSongMetadata(song)
                    case .itunes:
                        song = await SongMetadata.enrichWithiTunesMetadata(song)
                    case .deezer:
                        song = await SongMetadata.enrichWithDeezerMetadata(song)
                    case .apple:
                        song = await SongMetadata.enrichWithAppleMusicMetadata(song)
                    }
                }
            }
'''
new_cases = '''                    case .local:
                        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                            let enriched = await SongMetadata.matchAppleMusicMetadata(song)
                            if enriched.richAppleMetadataFetched {
                                song = enriched
                                if !sourcesUsed.contains(.apple) { sourcesUsed.append(.apple) }
                            }
                        }
                    case .youtube:
                        let filename = localURL.deletingPathExtension().lastPathComponent
                        if let videoID = MetadataProvider.extractYouTubeVideoID(from: filename) {
                            if let candidate = await MetadataProvider.fetchYouTubeMetadata(videoID: videoID) {
                                let parsed = MetadataProvider.normalizeYouTubeTitle(candidate.title, channel: candidate.channelTitle)
                                song.title = parsed.title
                                song.artist = parsed.artist
                                song.album = parsed.album
                                song.youtubeVideoID = videoID
                                if let thumbURL = candidate.thumbnailURL,
                                   let (data, _) = try? await URLSession.shared.data(from: thumbURL) {
                                    song.artworkData = data
                                }
                                if let duration = candidate.durationMs, duration > 0 { song.durationMs = duration }
                                if !sourcesUsed.contains(.youtube) { sourcesUsed.append(.youtube) }
                                Logger.shared.log("[MusicView] Enriched from YouTube: \\(song.title) - \\(song.artist)")
                            }
                        } else {
                            let searchQuery = "\\(song.artist) \\(song.title)"
                            let candidates = await MetadataProvider.searchYouTubeForMetadata(query: searchQuery, limit: 3)
                            if let bestMatch = candidates.first {
                                let parsed = MetadataProvider.normalizeYouTubeTitle(bestMatch.title, channel: bestMatch.channelTitle)
                                song.title = parsed.title
                                song.artist = parsed.artist
                                song.album = parsed.album
                                song.youtubeVideoID = bestMatch.videoID
                                if let thumbURL = bestMatch.thumbnailURL,
                                   let (data, _) = try? await URLSession.shared.data(from: thumbURL) {
                                    song.artworkData = data
                                }
                                if let duration = bestMatch.durationMs, duration > 0 { song.durationMs = duration }
                                if !sourcesUsed.contains(.youtube) { sourcesUsed.append(.youtube) }
                                Logger.shared.log("[MusicView] Enriched from YouTube search: \\(song.title) - \\(song.artist)")
                            }
                        }
                    case .itunes:
                        let enriched = await SongMetadata.enrichWithiTunesMetadata(song)
                        if enriched.title != song.title || enriched.artist != song.artist {
                            song = enriched
                            if !sourcesUsed.contains(.itunes) { sourcesUsed.append(.itunes) }
                        }
                    case .deezer:
                        let enriched = await SongMetadata.enrichWithDeezerMetadata(song)
                        if enriched.title != song.title || enriched.artist != song.artist {
                            song = enriched
                            if !sourcesUsed.contains(.deezer) { sourcesUsed.append(.deezer) }
                        }
                    case .apple:
                        let enriched = await SongMetadata.enrichWithAppleMusicMetadata(song)
                        if enriched.richAppleMetadataFetched {
                            song = enriched
                            if !sourcesUsed.contains(.apple) { sourcesUsed.append(.apple) }
                        }
                    }
                }
            }
            song.metadataSourcesUsed = sourcesUsed
'''
ms = replace_once(ms, old_cases, new_cases, "MusicView original provider cases")
music.write_text(ms)

print("Applied original ByeTunes metadata parity post-patch")
PY

grep -Fq 'persistMetadataSelection(newValue)' "$SETTINGS"
! grep -A8 -F '.onAppear {' "$SETTINGS" | grep -Fq 'persistMetadataSelection(metadataSource)'
grep -Fq 'metadataSource == "itunes" || metadataSource == "apple" || metadataSource == "all"' "$SETTINGS"
grep -Fq 'var youtubeVideoID: String? = nil' "$SONG"
grep -Fq 'var metadataSourcesUsed: [MetadataProviderID] = []' "$SONG"
grep -Fq 'song.metadataSourcesUsed = sourcesUsed' "$MUSIC"
grep -Fq '[MusicView] metadata sources=' "$MUSIC"
grep -Fq 'MetadataProvider.fetchYouTubeMetadata(videoID: videoID)' "$MUSIC"
grep -Fq 'candidates.first' "$MUSIC"
! grep -Fq 'MetadataProvider.enrichSongMetadata(song)' "$MUSIC"
grep -Fq 'static func searchYouTubeForMetadata(query: String, limit: Int = 5)' "$COMPAT"
grep -Fq 'static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil)' "$COMPAT"
grep -Fq 'https://noembed.com/embed?url=https://www.youtube.com/watch?v=' "$COMPAT"

echo "Verified original ByeTunes metadata state and first-result selection semantics"
