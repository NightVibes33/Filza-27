#!/bin/bash
set -euo pipefail

TARGET="ByeTunesMetadataCompat.swift"
MUSIC="ByeTunes/MusicManager/MusicView.swift"
BACKGROUND="ByeTunes/MusicManager/BackgroundMetadataFetchManager.swift"

for path in "$TARGET" "$MUSIC" "$BACKGROUND"; do
    test -f "$path"
done

python3 - "$TARGET" "$MUSIC" "$BACKGROUND" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
music = Path(sys.argv[2])
background = Path(sys.argv[3])
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


def enforce_strict_local_source(source_path: Path, label: str) -> None:
    source = source_path.read_text()

    # Patch the provider loop, not unrelated local-file switches. The picker
    # state has already been resolved by MetadataProviderSettings here.
    selection_anchor = "MetadataProviderSettings.selectedSources()"
    selection = source.find(selection_anchor)
    if selection < 0:
        raise SystemExit(f"{label}: selectedSources provider loop not found")

    local_token = "case .local:"
    youtube_token = "case .youtube:"
    local = source.find(local_token, selection)
    youtube = source.find(youtube_token, local + len(local_token)) if local >= 0 else -1
    if local < 0 or youtube < 0:
        raise SystemExit(f"{label}: local/youtube provider cases not found")

    line_start = source.rfind("\n", 0, local) + 1
    indent = source[line_start:local]
    local_block = source[local:youtube]

    # Local metadata is already parsed by SongMetadata.fromURL before this
    # provider loop. It must never become an implicit Apple Music provider.
    # In v2.4 that happened through appleRichMetadata ->
    # matchAppleMusicMetadata(), producing the "Shadow-searching Apple Music"
    # log even when the picker said Local Files or YouTube.
    strict_block = (
        "case .local:\n"
        f"{indent}    // Strict metadata selector gate: local means embedded/file metadata only.\n"
        f"{indent}    // Apple Music lookup is allowed only by the explicit .apple provider case.\n"
        f"{indent}    break\n"
        f"{indent}"
    )

    source = source[:local] + strict_block + source[youtube:]
    source_path.write_text(source)

    verified = source_path.read_text()
    selection = verified.find(selection_anchor)
    local = verified.find(local_token, selection)
    youtube = verified.find(youtube_token, local + len(local_token))
    local_block = verified[local:youtube]
    if "matchAppleMusicMetadata" in local_block or "enrichWithAppleMusicMetadata" in local_block:
        raise SystemExit(f"{label}: Apple Music call still reachable from local provider")
    if "Strict metadata selector gate" not in local_block:
        raise SystemExit(f"{label}: strict local-source marker missing")


enforce_strict_local_source(music, "foreground import")
enforce_strict_local_source(background, "background import")
PY

grep -Fq 'Match the original foreground import policy exactly' "$TARGET"
grep -Fq 'candidate = await searchYouTubeForMetadata(query: query, limit: 3).first' "$TARGET"
grep -Fq 'updated.youtubeVideoID = candidate.videoID' "$TARGET"
! grep -A40 -F 'static func enrichSongMetadata(_ song: SongMetadata)' "$TARGET" | grep -Fq 'matchScore('
grep -Fq 'Strict metadata selector gate: local means embedded/file metadata only.' "$MUSIC"
grep -Fq 'Strict metadata selector gate: local means embedded/file metadata only.' "$BACKGROUND"

echo "Verified foreground/background provider parity and strict metadata-source routing"
