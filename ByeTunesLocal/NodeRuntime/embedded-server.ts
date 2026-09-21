import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { detectPlatform } from "./lib/spotify";
import { resolveTrack } from "./lib/resolve-track";
import { prepareTrackAssets } from "./lib/track-prep";

const HOST = "127.0.0.1";
const PORT = Number(process.env.BYETUNES_YOINK_PORT || "41337");
const YOINK_COMMIT = "061e33ffc8d5050f828196bb78f7034f817e1e2e";

function json(res: ServerResponse, status: number, body: unknown) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": String(data.length),
    "Cache-Control": "no-store",
  });
  res.end(data);
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += b.length;
    if (size > 1024 * 1024) throw new Error("request too large");
    chunks.push(b);
  }
  if (!chunks.length) return {};
  const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  return parsed as Record<string, unknown>;
}

function mimeFor(format: string) {
  if (format === "flac") return "audio/flac";
  if (format === "webm") return "audio/webm";
  return "audio/mpeg";
}

async function metadata(req: IncomingMessage, res: ServerResponse) {
  try {
    const body = await readJson(req);
    const url = body.url;
    if (!url || typeof url !== "string") {
      return json(res, 400, { error: "URL is required" });
    }

    const platform = detectPlatform(url);
    if (!platform) {
      return json(res, 400, { error: "paste a spotify, deezer, or apple music link" });
    }

    const resolved = await resolveTrack(url);
    if (!resolved) {
      return json(res, 404, { error: "couldn't find this track — try a different link" });
    }

    return json(res, 200, { type: "track", ...resolved.track });
  } catch (error) {
    console.error("[ByeTunesLocal] metadata error", error);
    return json(res, 500, { error: "metadata failed — please try again" });
  }
}

async function download(req: IncomingMessage, res: ServerResponse) {
  try {
    const body = await readJson(req);
    const url = body.url;
    if (!url || typeof url !== "string") {
      return json(res, 400, { error: "URL is required" });
    }

    const platform = detectPlatform(url);
    if (!platform) {
      return json(res, 400, { error: "paste a spotify, deezer, or apple music link" });
    }

    const resolved = await resolveTrack(url);
    if (!resolved) {
      return json(res, 404, { error: "couldn't find this track — try a different link" });
    }

    const requestedFormat = typeof body.format === "string" ? body.format : undefined;
    const genreSource = typeof body.genreSource === "string" ? body.genreSource : undefined;
    const syncedLyrics = body.syncedLyrics === true;

    const assets = await prepareTrackAssets(resolved.track, {
      requestedFormat,
      genreSource,
      syncedLyrics,
    });

    // NodeMobile cannot spawn the server's ffmpeg binary. Until the native
    // FFmpeg bridge is connected, serve Yoink's verified source audio exactly
    // as fetched. The endpoint remains hidden from ByeTunes UI during this gate.
    const audio = assets.audio;
    const filename = `${resolved.track.artist} - ${resolved.track.name} · yoink.${audio.format}`;
    const headers: Record<string, string> = {
      "Content-Type": mimeFor(audio.format),
      "Content-Disposition": `attachment; filename="${encodeURIComponent(filename)}"`,
      "Content-Length": String(audio.buffer.length),
      "X-Audio-Source": audio.source,
      "X-Audio-Quality": String(audio.bitrate),
      "X-Audio-Format": audio.format,
      "X-ByeTunes-Local-Raw": "1",
      "Cache-Control": "no-store",
    };

    res.writeHead(200, headers);
    res.end(audio.buffer);
  } catch (error) {
    console.error("[ByeTunesLocal] download error", error);
    return json(res, 500, { error: "download failed — please try again" });
  }
}

const server = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    return json(res, 200, {
      ok: true,
      service: "byetunes-local-yoink",
      yoinkCommit: YOINK_COMMIT,
      platforms: ["spotify", "deezer", "apple-music"],
      youtube: false,
      node: process.version,
      pid: process.pid,
    });
  }

  if (req.method === "POST" && req.url === "/api/metadata") {
    return metadata(req, res);
  }

  if (req.method === "POST" && req.url === "/api/download") {
    return download(req, res);
  }

  return json(res, 404, { error: "not found" });
});

server.on("error", (error) => {
  console.error("[ByeTunesLocal] server error", error);
});

server.listen(PORT, HOST, () => {
  console.log(`[ByeTunesLocal] listening on http://${HOST}:${PORT}`);
});
