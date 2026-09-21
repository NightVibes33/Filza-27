#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()

def replace_once(rel, old, new):
    p = root / rel
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{rel}: expected exactly one match, got {count}: {old[:120]!r}")
    p.write_text(s.replace(old, new, 1))

replace_once(
    "src/lib/spotify.ts",
    'export function detectPlatform(url: string): "spotify" | "apple-music" | "youtube" | null {\n'
    '  if (url.includes("spotify.com") || url.includes("spotify:")) return "spotify";\n'
    '  if (url.includes("music.apple.com")) return "apple-music";\n'
    '  if (url.includes("youtube.com/watch") || url.includes("youtu.be/") || url.includes("music.youtube.com")) return "youtube";\n'
    '  return null;\n'
    '}',
    'export function detectPlatform(url: string): "spotify" | "apple-music" | "youtube" | "deezer" | null {\n'
    '  if (url.includes("spotify.com") || url.includes("spotify:")) return "spotify";\n'
    '  if (url.includes("music.apple.com")) return "apple-music";\n'
    '  if (url.includes("deezer.com") || url.includes("deezer.page.link") || url.includes("link.deezer.com")) return "deezer";\n'
    '  if (url.includes("youtube.com/watch") || url.includes("youtu.be/") || url.includes("music.youtube.com")) return "youtube";\n'
    '  return null;\n'
    '}'
)

marker = '/** Main resolver — detects platform and dispatches to the right chain. */'
helper = r'''async function resolveDirectDeezerTrack(url: string): Promise<TrackInfo | null> {
  let effectiveUrl = url;

  if (url.includes("deezer.page.link") || url.includes("link.deezer.com")) {
    try {
      const response = await fetch(url, {
        method: "HEAD",
        redirect: "follow",
        signal: AbortSignal.timeout(10000),
      });
      effectiveUrl = response.url || url;
    } catch {
      try {
        const response = await fetch(url, {
          method: "GET",
          redirect: "follow",
          signal: AbortSignal.timeout(10000),
        });
        effectiveUrl = response.url || url;
      } catch {
        return null;
      }
    }
  }

  const match = effectiveUrl.match(/deezer\.com\/(?:[a-z]{2}\/)?track\/(\d+)/i);
  if (!match) return null;

  const deezer = await fetchDeezerTrackMetadata(match[1]);
  if (!deezer) return null;

  return {
    ...deezer,
    spotifyUrl: effectiveUrl,
    label: null,
    copyright: null,
    compilation: isCompilationAlbum(deezer.albumArtist),
  };
}

'''
replace_once("src/lib/resolve-track.ts", marker, helper + marker)

replace_once(
    "src/lib/resolve-track.ts",
    '  if (platform === "apple-music") {\n    track = await resolveAppleMusicTrack(url);',
    '  if (platform === "deezer") {\n    track = await resolveDirectDeezerTrack(url);\n  } else if (platform === "apple-music") {\n    track = await resolveAppleMusicTrack(url);'
)

for rel in ("src/app/api/download/route.ts", "src/app/api/metadata/route.ts"):
    replace_once(
        rel,
        'paste a spotify, apple music, or youtube link',
        'paste a spotify, deezer, or apple music link'
    )

print("Applied ByeTunes direct-Deezer compatibility transform")
