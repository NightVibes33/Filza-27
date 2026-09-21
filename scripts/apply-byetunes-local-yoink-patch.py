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
    'export function detectPlatform(url: string): "spotify" | "apple-music" | "deezer" | null {\n'
    '  if (url.includes("spotify.com") || url.includes("spotify:")) return "spotify";\n'
    '  if (url.includes("music.apple.com")) return "apple-music";\n'
    '  if (url.includes("deezer.com") || url.includes("deezer.page.link") || url.includes("link.deezer.com")) return "deezer";\n'
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

replace_once(
    "src/lib/resolve-track.ts",
    '  } else if (platform === "youtube") {\n    const vid = extractYouTubeId(url);\n    if (!vid) return null;\n    youtubeVideoId = vid;\n    track = await resolveYouTubeTrack(vid, url);\n  } else {',
    '  } else {'
)

for rel in ("src/app/api/download/route.ts", "src/app/api/metadata/route.ts"):
    replace_once(
        rel,
        'paste a spotify, apple music, or youtube link',
        'paste a spotify, deezer, or apple music link'
    )


# ByeTunes removed YouTube as an accepted platform and as an audio fallback.
replace_once(
    "src/lib/resolve-track.ts",
    ' *   Apple Music: iTunes lookup by ID → Song.link/Deezer → Spotify API\n *   YouTube:     Song.link cross-ref → Deezer/iTunes search by parsed title+artist → Piped fallback\n',
    ' *   Apple Music: iTunes lookup by ID → Song.link/Deezer → Spotify API\n'
)

replace_once(
    "src/lib/resolve-track.ts",
    'import { getTrackInfo, detectPlatform, extractYouTubeId, extractPlaylistId, extractAlbumId, extractArtistId, extractTrackId, type TrackInfo, type PlaylistInfo } from "./spotify";\nimport { getYouTubeTrackInfo } from "./youtube";',
    'import { getTrackInfo, detectPlatform, extractPlaylistId, extractAlbumId, extractArtistId, extractTrackId, type TrackInfo, type PlaylistInfo } from "./spotify";'
)

resolve_text = (root / "src/lib/resolve-track.ts").read_text()
youtube_start = resolve_text.find('/** Resolve a YouTube URL → full TrackInfo (always returns something). */')
youtube_end = resolve_text.find('// ---------------------------------------------------------------------------\n// Playlist/Album scraping', youtube_start)
if youtube_start == -1 or youtube_end == -1:
    raise SystemExit("resolve-track.ts: YouTube resolver block not found")
(root / "src/lib/resolve-track.ts").write_text(resolve_text[:youtube_start] + resolve_text[youtube_end:])

replace_once(
    "src/lib/audio-sources.ts",
    'import { withTidalThrottle } from "./semaphore";\nimport { searchYouTube, getAudioStreamUrl, ytdlpDownload } from "./youtube";',
    'import { withTidalThrottle } from "./semaphore";'
)

replace_once(
    "src/lib/audio-sources.ts",
    '  source: "deezer" | "tidal" | "youtube";\n  format: "mp3" | "flac" | "webm";',
    '  source: "deezer" | "tidal";\n  format: "mp3" | "flac";'
)

audio_text = (root / "src/lib/audio-sources.ts").read_text()
youtube_audio_start = audio_text.find('async function tryYouTube(track: TrackInfo): Promise<AudioResult> {')
youtube_audio_end = audio_text.find('export async function fetchBestAudio', youtube_audio_start)
if youtube_audio_start == -1 or youtube_audio_end == -1:
    raise SystemExit("audio-sources.ts: YouTube fallback block not found")
audio_text = audio_text[:youtube_audio_start] + audio_text[youtube_audio_end:]
audio_text = audio_text.replace(
'''  // Fall back to YouTube (always WebM/Opus, no FLAC available)
  const ytResult = await tryYouTube(track);

  // Skip ffprobe and AcoustID for YouTube to reduce CPU usage.
  // ffprobe quality info is not critical for YouTube (always webm/opus ~160kbps),
  // and fpcalc (AcoustID) is very CPU-intensive.

  return ytResult;
''',
'''  throw new Error("couldn't download audio from configured ByeTunes sources");
''',
1)
(root / "src/lib/audio-sources.ts").write_text(audio_text)

request_logging = root / "src/lib/request-logging.ts"
expected_request_logging = '''import type { NextRequest } from "next/server";
import { logEvent, newRequestId, requestLogContext, type LogEvent } from "./logger";

export function withRequestLogging(handler: (request: NextRequest) => Promise<Response>, startedEvent: LogEvent) {
  return (request: NextRequest): Promise<Response> => {
    const requestId = newRequestId();
    return requestLogContext.run({ requestId }, async () => {
      logEvent(startedEvent);
      try {
        let response = await handler(request);
        logEvent(response.status >= 500 ? "request.failed" : response.status >= 400 ? "request.rejected" : "request.completed", response.status);
        // Include the same support ID in all JSON errors, including validation
        // and rate-limit failures. Do not consume audio or streaming responses.
        if (!response.ok && response.headers.get("content-type")?.includes("application/json")) {
          const body = await response.json();
          const headers = new Headers(response.headers);
          headers.delete("content-length");
          response = Response.json({ ...body, requestId }, { status: response.status, headers });
        }
        response.headers.set("X-Request-ID", requestId);
        response.headers.set("Cache-Control", "no-store");
        return response;
      } catch {
        logEvent("request.failed");
        return Response.json(
          { error: "something went wrong — please try again", requestId },
          { status: 500, headers: { "X-Request-ID": requestId, "Cache-Control": "no-store" } },
        );
      }
    });
  };
}
'''
actual_request_logging = request_logging.read_text()
if actual_request_logging != expected_request_logging:
    raise SystemExit("src/lib/request-logging.ts did not match pinned Yoink source")

request_logging.write_text('''import type { NextRequest } from "next/server";
import { logEvent, type LogEvent } from "./logger";

export function withRequestLogging(handler: (request: NextRequest) => Promise<Response>, startedEvent: LogEvent) {
  return async (request: NextRequest): Promise<Response> => {
    logEvent(startedEvent);
    try {
      const response = await handler(request);
      logEvent(response.status >= 500 ? "request.failed" : response.status >= 400 ? "request.rejected" : "request.completed", response.status);
      return response;
    } catch {
      logEvent("request.failed");
      return Response.json(
        { error: "something went wrong — please try again" },
        { status: 500 },
      );
    }
  };
}
''')


print("Applied ByeTunes direct-Deezer + Edu response compatibility transform")
