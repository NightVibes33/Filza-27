#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DOWNLOAD="$ROOT/DownloadView.swift"
SONG="$ROOT/SongMetadata.swift"
CONFIG="$ROOT/Config.swift"

for file in "$DOWNLOAD" "$SONG" "$CONFIG"; do
  test -s "$file" || {
    echo "missing ByeTunes source: $file" >&2
    exit 1
  }
done

python3 - "$DOWNLOAD" "$SONG" "$CONFIG" <<'PY'
from pathlib import Path
import sys

download = Path(sys.argv[1])
song = Path(sys.argv[2])
config = Path(sys.argv[3])

def find_balanced_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit("opening brace not found")
    depth = 0
    in_string = False
    escaped = False
    i = brace
    while i < len(text):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit("unbalanced Swift block")

def trim_block_tail(text: str, end: int) -> int:
    while end < len(text) and text[end] in " \t":
        end += 1
    if end < len(text) and text[end] == "\r":
        end += 1
    if end < len(text) and text[end] == "\n":
        end += 1
    return end

def remove_braced_block(text: str, marker: str, required: bool = True) -> tuple[str, bool]:
    start = text.find(marker)
    if start < 0:
        if required:
            raise SystemExit(f"required marker not found: {marker}")
        return text, False
    end = trim_block_tail(text, find_balanced_end(text, start))
    return text[:start] + text[end:], True

def replace_braced_function(text: str, signature: str, replacement: str, required: bool = True) -> tuple[str, bool]:
    start = text.find(signature)
    if start < 0:
        if required:
            raise SystemExit(f"required function not found: {signature}")
        return text, False
    end = trim_block_tail(text, find_balanced_end(text, start))
    return text[:start] + replacement.rstrip() + "\n" + text[end:], True

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

# Config.plist and the private ByeTunes origin are not part of the Filza build.
config.write_text(
'''import Foundation

struct Config {
    // Filza's embedded ByeTunes build intentionally has no private backend.
    // Metadata comes from Apple/iTunes/Deezer and lyrics come from LRCLIB.
    static let byeTunesApiUrl = ""
    static let byeTunesApiHost = ""
    static let downloadBackendLabel = "Disabled"
}
'''
)

dv = download.read_text()

# Remove the private /api/metadata transport. Spotify links continue through
# the public Spotify token/page/embed fallbacks already implemented upstream.
if "private func fetchSpotifyMetadata(url: String)" in dv:
    dv, _ = replace_braced_function(
        dv,
        "    private func fetchSpotifyMetadata(url: String) async -> [String: Any]? {",
        ""
    )

metadata_marker = "        if let json = await fetchSpotifyMetadata(url: sourceURL)"
removed_metadata_calls = 0
while metadata_marker in dv:
    dv, _ = remove_braced_block(dv, metadata_marker)
    removed_metadata_calls += 1
if removed_metadata_calls not in (0, 4):
    raise SystemExit(f"expected 4 private Spotify metadata call sites or an already-patched file; removed {removed_metadata_calls}")

# The standalone downloader was removed from Filza. Leave the upstream queue
# types compilable, but never construct a request to ByeTunes /api/download.
download_replacement = '''    private func downloadBackendCandidates(
        for source: DownloadSourceChoice,
        track: DownloadTrack? = nil
    ) async throws -> [BackendCandidate] {
        _ = source
        _ = track
        return []
    }'''
if "/api/download" in dv or "Config.byeTunesApiUrl" in dv:
    dv, _ = replace_braced_function(
        dv,
        "    private func downloadBackendCandidates(",
        download_replacement
    )

for forbidden in ("/api/metadata", "/api/download", "Config.byeTunesApiUrl"):
    if forbidden in dv:
        raise SystemExit(f"private ByeTunes backend marker remains in DownloadView.swift: {forbidden}")
for required in (
    "SongMetadata.searchiTunes",
    "SongMetadata.searchDeezer",
    "https://open.spotify.com/get_access_token",
    "fetchSpotifyTrackFromPublicPage",
):
    if required not in dv:
        raise SystemExit(f"public metadata fallback missing from DownloadView.swift: {required}")
download.write_text(dv)

sm = song.read_text()

# Only expose LRCLIB in Filza's lyric picker. The upstream enum cases stay in
# place for source compatibility, but Filza does not depend on their unofficial
# transports.
lyrics_enum_old = '''enum LyricsSearchService: String, CaseIterable, Identifiable {
    case lrclib
    case musixmatch
    case netease

    var id: String { rawValue }
'''
lyrics_enum_new = '''enum LyricsSearchService: String, CaseIterable, Identifiable {
    case lrclib
    case musixmatch
    case netease

    static var allCases: [LyricsSearchService] { [.lrclib] }

    var id: String { rawValue }
'''
if "static var allCases: [LyricsSearchService] { [.lrclib] }" not in sm:
    sm = replace_once(sm, lyrics_enum_old, lyrics_enum_new, "LRCLIB-only picker")

# Preserve LRC timestamps. Upstream cleanLyrics intentionally strips them,
# which made a synced LRCLIB result silently become plain lyrics.
if "static func cleanSyncedLyrics(" not in sm:
    synced_cleaner = r'''    static func cleanSyncedLyrics(_ rawLyrics: String, title: String? = nil, artist: String? = nil) -> String {
        _ = title
        _ = artist

        let metadataPattern = #"^\[(?:ar|ti|al|by|offset|re|ve|length):[^\]]*\]\s*$"#
        let timestampPattern = #"^(?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+"#
        let metadataRegex = try? NSRegularExpression(pattern: metadataPattern, options: [.caseInsensitive])
        let timestampRegex = try? NSRegularExpression(pattern: timestampPattern)

        var output: [String] = []
        for rawLine in rawLyrics.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if metadataRegex?.firstMatch(in: line, range: range) != nil {
                continue
            }
            guard timestampRegex?.firstMatch(in: line, range: range) != nil else {
                continue
            }
            output.append(line)
        }

        return output.joined(separator: "\n")
    }

'''
    marker = "    static func fetchLyricsFromLRCLIB(title: String, artist: String, album: String, durationMs: Int) async -> String? {"
    if marker not in sm:
        raise SystemExit("LRCLIB exact lookup marker missing")
    sm = sm.replace(marker, synced_cleaner + marker, 1)

lrclib_old = '''            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let lyrics = (json?["plainLyrics"] as? String) ?? (json?["syncedLyrics"] as? String)
            
            if let l = lyrics, !l.isEmpty {
                Logger.shared.log("[SongMetadata] Successfully fetched lyrics from LRCLIB")
                return SongMetadata.cleanLyrics(l, title: title, artist: artist)
            }
'''
lrclib_new = '''            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let synced = json?["syncedLyrics"] as? String,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = SongMetadata.cleanSyncedLyrics(synced, title: title, artist: artist)
                if !cleaned.isEmpty {
                    Logger.shared.log("[SongMetadata] Successfully fetched synced lyrics from LRCLIB")
                    return cleaned
                }
            }

            if let plain = json?["plainLyrics"] as? String,
               !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = SongMetadata.cleanLyrics(plain, title: title, artist: artist)
                if !cleaned.isEmpty {
                    Logger.shared.log("[SongMetadata] Successfully fetched plain lyrics from LRCLIB")
                    return cleaned
                }
            }
'''
if "Successfully fetched synced lyrics from LRCLIB" not in sm:
    sm = replace_once(sm, lrclib_old, lrclib_new, "LRCLIB exact synced/plain preference")

# Automatic lyric enrichment is LRCLIB-only: synced first, plain fallback.
auto_replacement = '''    static func fetchLyrics(title: String, artist: String, album: String, durationMs: Int) async -> String? {
        await fetchLyricsFromLRCLIB(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }'''
current_auto_sig = "    static func fetchLyrics(title: String, artist: String, album: String, durationMs: Int) async -> String? {"
auto_start = sm.find(current_auto_sig)
if auto_start < 0:
    raise SystemExit("automatic lyrics function missing")
auto_end = find_balanced_end(sm, auto_start)
auto_text = sm[auto_start:auto_end]
if "fetchLyricsFromMusixMatch" in auto_text or "fetchLyricsFromNetEase" in auto_text:
    sm = sm[:auto_start] + auto_replacement + sm[auto_end:]

resolve_old = '''        case .lrclib:
            let raw = result.syncedLyrics ?? result.plainLyrics ?? ""
            let cleaned = cleanLyrics(raw, title: songTitle, artist: songArtist)
            return cleaned.isEmpty ? nil : cleaned
'''
resolve_new = '''        case .lrclib:
            if let synced = result.syncedLyrics,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = cleanSyncedLyrics(synced, title: songTitle, artist: songArtist)
                return cleaned.isEmpty ? nil : cleaned
            }
            let cleaned = cleanLyrics(result.plainLyrics ?? "", title: songTitle, artist: songArtist)
            return cleaned.isEmpty ? nil : cleaned
'''
if resolve_old in sm:
    sm = replace_once(sm, resolve_old, resolve_new, "manual LRCLIB synced/plain preference")
elif "let cleaned = cleanSyncedLyrics(synced" not in sm:
    raise SystemExit("manual LRCLIB resolver is neither upstream nor patched")

for required in (
    "https://lrclib.net/api/get",
    "https://lrclib.net/api/search",
    "static func cleanSyncedLyrics",
    "Successfully fetched synced lyrics from LRCLIB",
):
    if required not in sm:
        raise SystemExit(f"required LRCLIB behavior missing: {required}")
song.write_text(sm)

print("Applied Filza public ByeTunes metadata + LRCLIB policy")
PY

! grep -Fq '/api/metadata' "$DOWNLOAD"
! grep -Fq '/api/download' "$DOWNLOAD"
! grep -Fq 'ByeTunesApiUrl' "$CONFIG"
! grep -Fq 'path(forResource: "Config"' "$CONFIG"
grep -Fq 'SongMetadata.searchiTunes' "$DOWNLOAD"
grep -Fq 'SongMetadata.searchDeezer' "$DOWNLOAD"
grep -Fq 'https://itunes.apple.com/search' "$SONG"
grep -Fq 'https://api.deezer.com/search' "$SONG"
grep -Fq 'https://lrclib.net/api/get' "$SONG"
grep -Fq 'https://lrclib.net/api/search' "$SONG"
grep -Fq 'static func cleanSyncedLyrics' "$SONG"
grep -Fq 'static var allCases: [LyricsSearchService] { [.lrclib] }' "$SONG"

echo "Verified public metadata providers and LRCLIB synced/plain lyrics"


# Filza's free rich-lyrics layer.  iOS 26.2+ / iOS 27 MusicKitInternal has a
# custom-lyrics path distinct from subscription/catalog lyrics.  Keep AMLL or
# LRCLIB timing as TTML in the custom library lyric field rather than claiming
# Apple store lyrics are available.
BUILDER="$ROOT/MediaLibraryBuilder.swift"
SETTINGS="$ROOT/SettingsView.swift"
for file in "$BUILDER" "$SETTINGS"; do
  test -s "$file" || {
    echo "missing ByeTunes rich-lyrics source: $file" >&2
    exit 1
  }
done

python3 - "$SONG" "$BUILDER" "$SETTINGS" <<'PY'
from pathlib import Path
import sys

song_path = Path(sys.argv[1])
builder_path = Path(sys.argv[2])
settings_path = Path(sys.argv[3])

sm = song_path.read_text()
mb = builder_path.read_text()
sv = settings_path.read_text()

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)

field_anchor = """    var localFileHasSpatialAudio: Bool = false
    
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var lyrics: String?
    
    var storeId: Int64 = 0
"""
field_block = """    var localFileHasSpatialAudio: Bool = false
    
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var lyrics: String?
    var syncedLyricsTTML: String? = nil
    var syncedLyricsSource: String? = nil
    var syncedLyricsTiming: String? = nil
    
    var storeId: Int64 = 0
"""
if "var syncedLyricsTTML: String?" not in sm:
    sm = replace_once(sm, field_anchor, field_block, "SongMetadata rich lyric fields")

helper_marker = "    static func fetchLyricsFromLRCLIB(title: String, artist: String, album: String, durationMs: Int) async -> String? {"
if "static func resolveFreeSyncedLyrics(for song: SongMetadata)" not in sm:
    helper = r'''    static func resolveFreeSyncedLyrics(for song: SongMetadata) async -> (ttml: String?, text: String?, source: String, timing: String)? {
        if song.storeId > 0,
           let rich = await fetchAMLLTTML(appleMusicID: song.storeId) {
            return (rich.ttml, song.lyrics, "amll", rich.timing)
        }

        if let existing = song.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty,
           isSyncedLRC(existing),
           let ttml = customTTMLFromLRC(existing, durationMs: song.durationMs) {
            return (ttml, plainTextFromLRC(existing), "embedded-lrc", "line")
        }

        if let fetched = await fetchLyrics(
            title: song.title,
            artist: song.artist,
            album: song.album,
            durationMs: song.durationMs
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fetched.isEmpty {
            if isSyncedLRC(fetched),
               let ttml = customTTMLFromLRC(fetched, durationMs: song.durationMs) {
                Logger.shared.log("[ByeTunesRichLyrics] LRCLIB synced LRC converted to custom TTML")
                return (ttml, plainTextFromLRC(fetched), "lrclib", "line")
            }
            Logger.shared.log("[ByeTunesRichLyrics] LRCLIB plain lyrics fallback")
            return (nil, fetched, "lrclib", "plain")
        }

        if let existing = song.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return (nil, existing, "embedded", "plain")
        }
        return nil
    }

    private static func fetchAMLLTTML(appleMusicID: Int64) async -> (ttml: String, timing: String)? {
        let base = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/am-lyrics"
        guard let url = URL(string: "\(base)/\(appleMusicID).ttml") else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 8)
        request.setValue("text/xml, application/xml, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("ByeTunes/2.5 (Filza-27; synced-lyrics)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  !data.isEmpty,
                  data.count <= 2 * 1024 * 1024,
                  let raw = String(data: data, encoding: .utf8) else {
                return nil
            }

            let ttml = normalizeCustomTTML(raw)
            guard isValidCustomTTML(ttml) else {
                Logger.shared.log("[ByeTunesRichLyrics] AMLL response rejected appleMusicId=\(appleMusicID)")
                return nil
            }

            let wordTimed = ttml.range(
                of: #"itunes:timing\s*=\s*[\"']Word[\"']"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let timing = wordTimed ? "word" : "line"
            Logger.shared.log("[ByeTunesRichLyrics] AMLL TTML hit appleMusicId=\(appleMusicID) timing=\(timing) bytes=\(data.count)")
            return (ttml, timing)
        } catch {
            Logger.shared.log("[ByeTunesRichLyrics] AMLL miss appleMusicId=\(appleMusicID): \(error.localizedDescription)")
            return nil
        }
    }

    static func normalizeCustomTTML(_ source: String) -> String {
        var text = source
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func isValidCustomTTML(_ source: String) -> Bool {
        let text = normalizeCustomTTML(source)
        return (text.hasPrefix("<tt ") || text.hasPrefix("<tt>"))
            && text.range(of: "</tt>", options: .caseInsensitive) != nil
            && text.range(of: "<body", options: .caseInsensitive) != nil
            && text.range(of: "<p", options: .caseInsensitive) != nil
            && text.range(of: "begin=", options: .caseInsensitive) != nil
    }

    static func isSyncedLRC(_ source: String) -> Bool {
        source.range(
            of: #"(?m)^\s*(?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+"#,
            options: .regularExpression
        ) != nil
    }

    static func customTTMLFromLRC(_ lrc: String, durationMs: Int) -> String? {
        struct TimedLine {
            let start: Double
            let text: String
        }

        let prefixPattern = #"^\s*((?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\]\s*)+)(.*)$"#
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let prefixRegex = try? NSRegularExpression(pattern: prefixPattern),
              let timestampRegex = try? NSRegularExpression(pattern: timestampPattern) else {
            return nil
        }

        var lines: [TimedLine] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let full = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = prefixRegex.firstMatch(in: rawLine, range: full),
                  let prefixRange = Range(match.range(at: 1), in: rawLine),
                  let textRange = Range(match.range(at: 2), in: rawLine) else {
                continue
            }

            let lyric = rawLine[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyric.isEmpty else { continue }

            let prefix = String(rawLine[prefixRange])
            let prefixNS = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
            for timestamp in timestampRegex.matches(in: prefix, range: prefixNS) {
                guard let minuteRange = Range(timestamp.range(at: 1), in: prefix),
                      let secondRange = Range(timestamp.range(at: 2), in: prefix) else {
                    continue
                }

                let minutes = Double(prefix[minuteRange]) ?? 0
                let seconds = Double(prefix[secondRange]) ?? 0
                var fraction = 0.0
                if timestamp.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(timestamp.range(at: 3), in: prefix) {
                    let digits = String(prefix[fractionRange])
                    if let value = Double(digits) {
                        if digits.count == 1 { fraction = value / 10 }
                        else if digits.count == 2 { fraction = value / 100 }
                        else { fraction = value / 1000 }
                    }
                }
                lines.append(TimedLine(start: minutes * 60 + seconds + fraction, text: lyric))
            }
        }

        lines.sort {
            if $0.start == $1.start { return $0.text < $1.text }
            return $0.start < $1.start
        }
        guard !lines.isEmpty else { return nil }

        let trackEnd = max(Double(durationMs) / 1000, (lines.last?.start ?? 0) + 4)
        var paragraphs: [String] = []
        for index in lines.indices {
            let line = lines[index]
            let next = index + 1 < lines.count ? lines[index + 1].start : trackEnd
            let end = max(line.start + 0.05, next)
            paragraphs.append(
                #"<p begin="\#(formatTTMLTime(line.start))" end="\#(formatTTMLTime(end))" itunes:key="L\#(index + 1)">\#(escapeTTMLText(line.text))</p>"#
            )
        }

        return #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="und" itunes:timing="Line"><head><metadata/></head><body><div>"#
            + paragraphs.joined()
            + "</div></body></tt>"
    }

    static func plainTextFromLRC(_ source: String) -> String {
        let timestampPattern = #"(?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+"#
        let metadataPattern = #"^\s*\[(?:ar|ti|al|by|offset|re|ve|length):[^\]]*\]\s*$"#
        let metadataRegex = try? NSRegularExpression(pattern: metadataPattern, options: [.caseInsensitive])

        return source.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if metadataRegex?.firstMatch(in: line, range: range) != nil { return nil }
            let stripped = line.replacingOccurrences(
                of: timestampPattern,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }.joined(separator: "\n")
    }

    private static func formatTTMLTime(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let minutes = Int(safe) / 60
        let remainder = safe - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, remainder)
    }

    private static func escapeTTMLText(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

'''
    if helper_marker not in sm:
        raise SystemExit("LRCLIB helper marker missing")
    sm = sm.replace(helper_marker, helper + helper_marker, 1)

enrichment_old = '''        let fetchLyricsEnabled = UserDefaults.standard.bool(forKey: "fetchLyrics")
        let appleSubscriptionLyrics = UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")
        if fetchLyricsEnabled && !appleSubscriptionLyrics && (song.lyrics == nil || song.lyrics?.isEmpty == true) {
            if let fetchedLyrics = await SongMetadata.fetchLyrics(
                title: song.title,
                artist: song.artist,
                album: song.album,
                durationMs: song.durationMs
            ) {
                song.lyrics = fetchedLyrics
            }
        }
'''
enrichment_new = '''        let fetchLyricsEnabled = (UserDefaults.standard.object(forKey: "fetchLyrics") as? Bool) ?? true
        if fetchLyricsEnabled,
           let resolved = await SongMetadata.resolveFreeSyncedLyrics(for: song) {
            if let text = resolved.text, !text.isEmpty {
                song.lyrics = text
            }
            song.syncedLyricsTTML = resolved.ttml
            song.syncedLyricsSource = resolved.source
            song.syncedLyricsTiming = resolved.timing
            Logger.shared.log("[ByeTunesRichLyrics] resolved source=\(resolved.source) timing=\(resolved.timing) nativeCustomTTML=\(resolved.ttml != nil)")
        }
'''
if "resolveFreeSyncedLyrics(for: song)" not in sm:
    sm = replace_once(sm, enrichment_old, enrichment_new, "rich lyric enrichment")

builder_old = '''            let appleSubscriptionLyrics = UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")
            let resolvedLyricsText = appleSubscriptionLyrics ? "" : SongMetadata.cleanLyrics(song.lyrics ?? "", title: song.title, artist: song.artist)
            let lyricsContent = resolvedLyricsText.replacingOccurrences(of: "'", with: "''")

            if columnExists(db: db, tableName: "lyrics", columnName: "downloaded_catalog_lyrics_available") {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available, downloaded_catalog_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', 1, 1, 0)
                """)
            } else {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', 1, 1)
                """)
            }
'''
builder_new = '''            // Community timing is custom/library TTML, not Apple subscription/store lyrics.
            let fallbackTimedTTML = SongMetadata.customTTMLFromLRC(song.lyrics ?? "", durationMs: song.durationMs)
            let customTimedTTML = song.syncedLyricsTTML ?? fallbackTimedTTML
            let hasCustomTimedLyrics = customTimedTTML != nil
            let resolvedLyricsText = customTimedTTML
                ?? SongMetadata.cleanLyrics(song.lyrics ?? "", title: song.title, artist: song.artist)
            let lyricsContent = resolvedLyricsText.replacingOccurrences(of: "'", with: "''")
            let storeLyricsAvailable = 0
            let timeSyncedLyricsAvailable = hasCustomTimedLyrics ? 1 : 0

            Logger.shared.log("[ByeTunesRichLyrics] library write source=\(song.syncedLyricsSource ?? (hasCustomTimedLyrics ? "lrc" : "plain")) timing=\(song.syncedLyricsTiming ?? (hasCustomTimedLyrics ? "line" : "plain")) customTTML=\(hasCustomTimedLyrics)")

            if columnExists(db: db, tableName: "lyrics", columnName: "downloaded_catalog_lyrics_available") {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available, downloaded_catalog_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', \(storeLyricsAvailable), \(timeSyncedLyricsAvailable), 0)
                """)
            } else {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', \(storeLyricsAvailable), \(timeSyncedLyricsAvailable))
                """)
            }
'''
if "let hasCustomTimedLyrics = customTimedTTML != nil" not in mb:
    mb = replace_once(mb, builder_old, builder_new, "custom TTML database write")

settings_start = '                        if !appleSubscriptionLyrics {\n'
settings_end = '                        if metadataSource == "itunes" || metadataSource == "apple" || (metadataSource == "local" && appleRichMetadata) {\n'
if "Free synced lyric pipeline" not in sv:
    start = sv.find(settings_start)
    end = sv.find(settings_end, start)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("settings lyric section anchors missing")
    replacement = '''                        Divider().padding(.leading, 56)

                        Toggle(isOn: $fetchLyrics) {
                            HStack {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Synced Lyrics")
                                        .font(.body)
                                    Text("AMLL word-sync with LRCLIB fallback.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button {
                                    showInfo(
                                        "Synced Lyrics",
                                        "Free lyric pipeline: AMLL TTML by Apple Music catalog ID first, then LRCLIB synced LRC, then plain lyrics. No Apple Music subscription, Apple login, media-user-token, or music.apple.com cookie is used."
                                    )
                                } label: {
                                    infoButton
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)

                        Divider().padding(.leading, 56)

                        HStack {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Free synced lyric pipeline")
                                    .font(.body)
                                Text("AMLL → LRCLIB → plain lyrics")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)

'''
    sv = sv[:start] + replacement + sv[end:]

sv = sv.replace(
    '@AppStorage("fetchLyrics") private var fetchLyrics = false',
    '@AppStorage("fetchLyrics") private var fetchLyrics = true',
    1,
)
sv = sv.replace(
    '    @AppStorage("appleSubscriptionLyrics") private var appleSubscriptionLyrics = false\n',
    '',
    1,
)

required = (
    ("var syncedLyricsTTML: String?", sm),
    ("resolveFreeSyncedLyrics(for: song)", sm),
    ("https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/am-lyrics", sm),
    ('itunes:timing="Line"', sm),
    ("let hasCustomTimedLyrics = customTimedTTML != nil", mb),
    ("let storeLyricsAvailable = 0", mb),
    ("Free synced lyric pipeline", sv),
    ("AMLL → LRCLIB → plain lyrics", sv),
)
for needle, text in required:
    if needle not in text:
        raise SystemExit(f"required rich synced lyric marker missing: {needle}")

if "Apple Music Subscription Lyrics" in sv:
    raise SystemExit("subscription lyrics UI remains")
if "appleSubscriptionLyrics" in sv:
    raise SystemExit("legacy appleSubscriptionLyrics setting remains")
if "appleSubscriptionLyrics" in sm:
    raise SystemExit("legacy appleSubscriptionLyrics routing remains")
if "resolvedLyricsText = appleSubscriptionLyrics" in mb:
    raise SystemExit("subscription lyrics database branch remains")

song_path.write_text(sm)
builder_path.write_text(mb)
settings_path.write_text(sv)
print("Applied free AMLL/LRCLIB custom-TTML pipeline")
PY

grep -Fq 'var syncedLyricsTTML: String?' "$SONG"
grep -Fq 'resolveFreeSyncedLyrics(for: song)' "$SONG"
grep -Fq 'https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/am-lyrics' "$SONG"
grep -Fq 'itunes:timing="Line"' "$SONG"
grep -Fq 'let hasCustomTimedLyrics = customTimedTTML != nil' "$BUILDER"
grep -Fq 'let storeLyricsAvailable = 0' "$BUILDER"
grep -Fq 'Free synced lyric pipeline' "$SETTINGS"
! grep -Fq 'Apple Music Subscription Lyrics' "$SETTINGS"
! grep -Fq 'appleSubscriptionLyrics' "$SETTINGS"
! grep -Fq 'appleSubscriptionLyrics' "$SONG"

echo "Verified free rich synced-lyrics integration"
