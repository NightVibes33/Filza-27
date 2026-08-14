#!/bin/bash
set -euo pipefail

TARGET="ByeTunesMetadataCompat.swift"
test -f "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

signature = "    static func enrichSongMetadata(_ song: SongMetadata) async -> SongMetadata {"
start = text.find(signature)
if start < 0:
    raise SystemExit("MetadataProvider.enrichSongMetadata signature not found")
brace = text.find("{", start)
if brace < 0:
    raise SystemExit("MetadataProvider.enrichSongMetadata opening brace not found")

depth = 0
in_string = False
escape = False
i = brace
end = None
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
                end = i + 1
                break
    i += 1

if end is None:
    raise SystemExit("MetadataProvider.enrichSongMetadata closing brace not found")

replacement = '''    static func enrichSongMetadata(_ song: SongMetadata) async -> SongMetadata {
        // v2.4 background metadata fetch calls this compatibility helper.
        // Match the original foreground import policy exactly: use a YouTube
        // ID embedded in the filename first; otherwise take the first provider
        // search result. Do not rank candidates with a new score/threshold.
        let filename = song.localURL.deletingPathExtension().lastPathComponent

        let candidate: YouTubeMetadataCandidate?
        if let videoID = extractYouTubeVideoID(from: filename) {
            candidate = await fetchYouTubeMetadata(videoID: videoID)
        } else {
            let artist = song.artist.caseInsensitiveCompare("Unknown Artist") == .orderedSame ? "" : song.artist
            let query = [artist, song.title]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !query.isEmpty else { return song }
            candidate = await searchYouTubeForMetadata(query: query, limit: 3).first
        }

        guard let candidate else { return song }
        let normalized = normalizeYouTubeTitle(candidate.title, channel: candidate.channelTitle)
        var updated = song
        updated.title = normalized.title
        updated.artist = normalized.artist
        updated.album = normalized.album
        updated.youtubeVideoID = candidate.videoID

        if let durationMs = candidate.durationMs, durationMs > 0 {
            updated.durationMs = durationMs
        }
        if let thumbnailURL = candidate.thumbnailURL,
           let data = await fetchData(thumbnailURL, timeout: 5) {
            updated.artworkData = data
            updated.artworkPreviewData = data
        }

        Logger.shared.log("[MetadataProvider] YouTube metadata matched \\(updated.title) - \\(updated.artist)")
        return updated
    }'''

text = text[:start] + replacement + text[end:]
path.write_text(text)
PY

grep -Fq 'Match the original foreground import policy exactly' "$TARGET"
grep -Fq 'candidate = await searchYouTubeForMetadata(query: query, limit: 3).first' "$TARGET"
grep -Fq 'updated.youtubeVideoID = candidate.videoID' "$TARGET"
! grep -A40 -F 'static func enrichSongMetadata(_ song: SongMetadata)' "$TARGET" | grep -Fq 'matchScore('

echo "Verified foreground/background YouTube provider parity"
