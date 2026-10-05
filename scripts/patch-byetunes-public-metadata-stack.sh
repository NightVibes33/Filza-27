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
