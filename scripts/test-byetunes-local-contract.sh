#!/usr/bin/env bash
set -euo pipefail

LOCAL="${1:-http://127.0.0.1:3000}"
LIVE="${2:-https://api.byetunes.xyz}"
OUT="${3:-byetunes-local-contract}"
mkdir -p "$OUT"

post() {
  local base="$1" path="$2" body="$3" prefix="$4"
  local headers="$OUT/$prefix.headers"
  local response="$OUT/$prefix.body"
  local status
  status="$(curl -sS --connect-timeout 10 --max-time 35 -D "$headers" -o "$response" -w '%{http_code}'     -H 'Content-Type: application/json' --data "$body" "$base$path" || true)"
  printf '%s' "$status" > "$OUT/$prefix.status"
}

assert_pair() {
  local name="$1" path="$2" body="$3"
  post "$LOCAL" "$path" "$body" "$name.local"
  post "$LIVE" "$path" "$body" "$name.live"

  local ls rs lb rb
  ls="$(cat "$OUT/$name.local.status")"
  rs="$(cat "$OUT/$name.live.status")"
  lb="$(cat "$OUT/$name.local.body")"
  rb="$(cat "$OUT/$name.live.body")"

  printf '%-28s local=%s live=%s\n' "$name" "$ls" "$rs"
  printf '  local: %s\n' "$lb"
  printf '  live : %s\n' "$rb"

  if [[ "$ls" != "$rs" || "$lb" != "$rb" ]]; then
    echo "Contract mismatch: $name" >&2
    return 1
  fi
}

assert_pair download_missing /api/download '{}'
assert_pair download_unsupported /api/download '{"url":"https://example.com/not-a-track","format":"mp3","genreSource":"itunes","syncedLyrics":false}'
assert_pair download_deezer_missing /api/download '{"url":"https://www.deezer.com/track/0","format":"mp3","genreSource":"itunes","syncedLyrics":false}'
assert_pair download_spotify_missing /api/download '{"url":"https://open.spotify.com/track/0000000000000000000000","format":"mp3","genreSource":"spotify","syncedLyrics":false}'
assert_pair download_apple_missing /api/download '{"url":"https://music.apple.com/us/song/not-a-track/0","format":"mp3","genreSource":"apple","syncedLyrics":false}'
assert_pair download_youtube_probe /api/download '{"url":"https://www.youtube.com/watch?v=AAAAAAAAAAA","format":"mp3","genreSource":"youtube","syncedLyrics":false}'
assert_pair metadata_missing /api/metadata '{}'
assert_pair metadata_unsupported /api/metadata '{"url":"https://example.com/not-a-track"}'
assert_pair metadata_deezer_missing /api/metadata '{"url":"https://www.deezer.com/track/0"}'
assert_pair metadata_spotify_missing /api/metadata '{"url":"https://open.spotify.com/track/0000000000000000000000"}'
assert_pair metadata_apple_missing /api/metadata '{"url":"https://music.apple.com/us/song/not-a-track/0"}'
assert_pair metadata_youtube_probe /api/metadata '{"url":"https://www.youtube.com/watch?v=AAAAAAAAAAA"}'

echo "Local patched Yoink matches the observed ByeTunes contract for controlled non-media probes."
