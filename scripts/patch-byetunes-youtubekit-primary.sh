#!/usr/bin/env bash
set -euo pipefail

TARGET="ByeTunesMetadataCompat.swift"
YTK="ThirdParty/byetunes-youtubekit/Generated"

test -f "$TARGET" || { echo "Missing $TARGET" >&2; exit 1; }
test -f "$YTK/YouTube.swift" || { echo "YouTubeKit must be staged before provider patch" >&2; exit 1; }
test -f "$YTK/InnerTube.swift"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# These are the exact instance lists from NightVibes33/ByeTunes
# 1a90f9e0f2b1a1787b208809ad2373f5c52175c8. This patch is provider-only:
# it deliberately does not touch MusicView, SettingsView, or the editor.
invidious = '''    private static let invidiousInstances = [
        "https://invidious.darkness.services",
        "https://invidious.fdn.fr",
        "https://invidious.flokinet.to",
        "https://inv.thepixora.com",
        "https://inv.nadeko.net",
        "https://invidious.jing.rocks",
        "https://invidious.nerdvpn.de",
        "https://invidious.perennialte.ch",
        "https://invidious.drgns.space",
        "https://invidious.protokolla.fi",
        "https://invidious.privacydev.net",
        "https://invidious.private.coffee",
        "https://yt.drgnz.club",
        "https://inv.in.projectsegfau.lt",
        "https://invidious.reallyaweso.me",
        "https://invidious.materialio.us",
        "https://invidious.incogniweb.net",
        "https://invidious.privacyredirect.com",
        "https://inv.tux.pizza",
        "https://iv.nboeck.de",
        "https://iv.melmac.space",
        "https://iv.datura.network",
        "https://y.com.sb",
        "https://inv.riverside.rocks"
    ]'''

piped = '''    private static let pipedInstances = [
        "https://api.piped.projectsegfault.com",
        "https://pipedapi.moomoo.me",
        "https://pipedapi.adminforge.de",
        "https://pipedapi.mint.lgbt",
        "https://pipedapi.frontendfriendly.xyz",
        "https://pipedapi.moomoo.me",
        "https://api.piped.privacydev.net"
    ]'''

def replace_array(source: str, declaration: str, replacement: str) -> str:
    start = source.find(declaration)
    if start < 0:
        raise SystemExit(f"YouTubeKit parity patch failed: {declaration} not found")
    open_bracket = source.find("[", start)
    if open_bracket < 0:
        raise SystemExit(f"YouTubeKit parity patch failed: {declaration} has no array")
    depth = 0
    in_string = False
    escape = False
    end = None
    for i in range(open_bracket, len(source)):
        ch = source[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit(f"YouTubeKit parity patch failed: {declaration} array did not close")
    return source[:start] + replacement + source[end:]

text = replace_array(text, "    private static let invidiousInstances = [", invidious)
text = replace_array(text, "    private static let pipedInstances = [", piped)

signature = "    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil) async -> YouTubeMetadataCandidate? {"
start = text.find(signature)
if start < 0:
    raise SystemExit("YouTubeKit parity patch failed: post-v2.4 fetchYouTubeMetadata function missing")

# The preceding v2.4 parity patch keeps the API-key route first and then enters
# its free-provider fallback at the first Invidious loop. Insert the exact old
# YouTubeKit primary immediately before that loop, preserving API-key priority
# and every existing fallback after it.
next_function = text.find("\n    private static func ", start + len(signature))
function_scope_end = next_function if next_function >= 0 else len(text)
loop = text.find("        for base in invidiousInstances.shuffled() {", start, function_scope_end)
if loop < 0:
    raise SystemExit("YouTubeKit parity patch failed: direct metadata Invidious fallback anchor missing")

marker = "[YouTubeProvider] YouTubeKit metadata matched videoID="
if marker not in text[start:function_scope_end]:
    old_primary = '''        // Exact pre-v2.4 primary from NightVibes33/ByeTunes 1a90f9e0:
        // use the vendored YouTubeKit player metadata before public mirrors.
        do {
            let youtube = YouTube(videoID: videoID)
            let details = try await youtube.videoDetails
            guard let first = details.first else { throw YouTubeKitError.extractError }
            let title = first.title ?? ""
            let author = first.author ?? ""
            let lengthSeconds = first.lengthSeconds.flatMap(Int.init)
            let thumbnailURL = first.thumbnail.thumbnails.last?.url

            if !title.isEmpty || !author.isEmpty {
                Logger.shared.log("[YouTubeProvider] YouTubeKit metadata matched videoID=\\(videoID)")
                return YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: title,
                    channelTitle: author,
                    description: first.shortDescription,
                    thumbnailURL: thumbnailURL,
                    durationMs: lengthSeconds.map { $0 * 1000 }
                )
            }
        } catch {
            Logger.shared.log("[YouTubeProvider] YouTubeKit metadata failed: \\(error)")
        }

'''
    text = text[:loop] + old_primary + text[loop:]

path.write_text(text, encoding="utf-8")
PY

grep -Fq 'let youtube = YouTube(videoID: videoID)' "$TARGET"
grep -Fq '[YouTubeProvider] YouTubeKit metadata matched videoID=' "$TARGET"
grep -Fq 'https://invidious.flokinet.to' "$TARGET"
grep -Fq 'https://api.piped.projectsegfault.com' "$TARGET"

# Scope guard: this script must never alter the already-working import routing
# or metadata editor. Those files are intentionally not arguments above.
git diff -- ByeTunes/MusicManager/MusicView.swift ByeTunes/MusicManager/SettingsView.swift ByeTunes/MusicManager/ManualMetadataEditor.swift >/dev/null

echo "Restored exact pre-v2.4 YouTubeKit primary inside the v2.4 YouTube provider only"
