import http, { IncomingMessage, ServerResponse } from "node:http";
import {
  detectPlatform,
  detectUrlType,
  getPlaylistInfo,
  getAlbumInfo,
  getArtistTopTracks,
  type TrackInfo,
} from "./src/lib/spotify";
import {
  resolveTrack,
  resolvePlaylist,
  resolveAlbum,
  resolveArtist,
  getSpotifyFromUrl,
  type SpotifyFromUrlResponse,
  type SpotifyFromUrlTrack,
} from "./src/lib/resolve-track";
import { fetchBestAudio } from "./src/lib/audio-sources";
import { isCompilationAlbum } from "./src/lib/audio-metadata";

const HOST = "127.0.0.1";
const PORT = Number.parseInt(process.env.BYETUNES_YOINK_PORT || "41337", 10);
const MAX_BODY = 128 * 1024;

function json(res: ServerResponse, status: number, body: unknown) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": String(data.length),
    "Cache-Control": "no-store",
  });
  res.end(data);
}

function formatDuration(ms: number): string {
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  return String(minutes) + ":" + seconds.toString().padStart(2, "0");
}

function mapUnfurlTrack(track: SpotifyFromUrlTrack, collection: SpotifyFromUrlResponse["playlist_info"]): TrackInfo {
  const artist = track.artists.join("; ");
  const albumArtist = track.album_artists?.length
    ? track.album_artists.join("; ")
    : (collection.type === "album" || collection.type === "artist" ? artist : null);
  return {
    name: track.name,
    artist,
    albumArtist,
    compilation: track.compilation ?? isCompilationAlbum(albumArtist),
    album: track.album,
    albumArt: track.image?.url || track.thumb_image?.url || collection.images[0]?.url || "",
    duration: formatDuration(track.duration_ms),
    durationMs: track.duration_ms,
    isrc: track.external_ids?.isrc || null,
    genre: null,
    releaseDate: track.release_date || collection.release_date || null,
    spotifyUrl: track.external_url,
    explicit: track.explicit,
    trackNumber: track.track_number,
    discNumber: track.disc_number,
    label: null,
    copyright: track.copyright || null,
    totalTracks: track.total_tracks ?? (collection.type === "album" ? collection.total_tracks : null),
  };
}

function mapUnfurl(data: SpotifyFromUrlResponse) {
  const tracks = data.tracks.map((track) => mapUnfurlTrack(track, data.playlist_info));
  if (data.playlist_info.type === "track") {
    return tracks[0] ? { type: "track", ...tracks[0] } : null;
  }
  return {
    type: "playlist",
    name: data.playlist_info.name,
    image: data.playlist_info.images[0]?.url || tracks[0]?.albumArt || "",
    tracks,
  };
}

async function readJSON(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += b.length;
    if (total > MAX_BODY) throw new Error("request too large");
    chunks.push(b);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function metadata(body: Record<string, unknown>) {
  const url = body.url;
  if (!url || typeof url !== "string") return { status: 400, body: { error: "URL is required" } };

  const platform = detectPlatform(url);
  if (!platform) {
    return { status: 400, body: { error: "paste a spotify, deezer, or apple music link" } };
  }

  if (platform === "spotify") {
    const type = detectUrlType(url);
    const unfurled = await getSpotifyFromUrl(url, { enrichIsrc: true });
    if (unfurled) {
      const mapped = mapUnfurl(unfurled);
      if (mapped) return { status: 200, body: mapped };
    }

    if (type === "playlist") {
      const playlist = await getPlaylistInfo(url).catch(() => resolvePlaylist(url));
      if (playlist) return { status: 200, body: { type: "playlist", ...playlist } };
    } else if (type === "album") {
      const album = await getAlbumInfo(url).catch(() => resolveAlbum(url));
      if (album) return { status: 200, body: { type: "playlist", ...album } };
    } else if (type === "artist") {
      const artist = await getArtistTopTracks(url).catch(() => resolveArtist(url));
      if (artist) return { status: 200, body: { type: "playlist", ...artist } };
    }
  }

  const resolved = await resolveTrack(url);
  if (!resolved) {
    return { status: 404, body: { error: "couldn't find this track — try a different link" } };
  }

  return { status: 200, body: { type: "track", ...resolved.track } };
}

async function download(body: Record<string, unknown>) {
  const url = body.url;
  if (!url || typeof url !== "string") return { status: 400, json: { error: "URL is required" } };

  const platform = detectPlatform(url);
  if (!platform) {
    return { status: 400, json: { error: "paste a spotify, deezer, or apple music link" } };
  }

  const resolved = await resolveTrack(url);
  if (!resolved) {
    return { status: 404, json: { error: "couldn't find this track — try a different link" } };
  }

  try {
    const requestedFormat = typeof body.format === "string" ? body.format : "flac";
    const preferLossless = requestedFormat === "flac" || requestedFormat === "alac";
    const audio = await fetchBestAudio(resolved.track, preferLossless);
    const contentType = audio.format === "flac" ? "audio/flac" : "audio/mpeg";
    const filename = encodeURIComponent(resolved.track.artist + " - " + resolved.track.name + "." + audio.format);
    return {
      status: 200,
      audio: audio.buffer,
      headers: {
        "Content-Type": contentType,
        "Content-Length": String(audio.buffer.length),
        "Content-Disposition": "attachment; filename=\"" + filename + "\"",
        "X-Audio-Source": audio.source,
        "X-Audio-Quality": String(audio.bitrate),
        "X-Audio-Format": audio.format,
        "Cache-Control": "no-store",
      },
    };
  } catch (error) {
    console.error("[ByeTunesLocal] download failed", error instanceof Error ? error.message : String(error));
    return { status: 500, json: { error: "download failed — please try again" } };
  }
}

async function handle(req: IncomingMessage, res: ServerResponse) {
  if (req.method === "GET" && req.url === "/health") {
    return json(res, 200, {
      ok: true,
      service: "byetunes-local-yoink",
      host: HOST,
      port: PORT,
      youtube: false,
      providers: ["spotify", "deezer", "apple-music"],
      yoinkCommit: "061e33ffc8d5050f828196bb78f7034f817e1e2e",
      node: process.version,
      pid: process.pid,
    });
  }

  if (req.method !== "POST" || (req.url !== "/api/metadata" && req.url !== "/api/download")) {
    return json(res, 404, { error: "not found" });
  }

  try {
    const body = await readJSON(req);
    if (req.url === "/api/metadata") {
      const result = await metadata(body);
      return json(res, result.status, result.body);
    }

    const result = await download(body);
    if ("json" in result) return json(res, result.status, result.json);
    res.writeHead(result.status, result.headers);
    res.end(result.audio);
  } catch {
    return json(res, 400, { error: "invalid request" });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PORT, HOST, () => {
  console.log("[ByeTunesLocal] ready http://" + HOST + ":" + PORT);
});
