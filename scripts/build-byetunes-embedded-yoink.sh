#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.theos/byetunes-yoink-bundle}"
WORK="${RUNNER_TEMP:-$ROOT/.build}/byetunes-embedded-yoink"
YOINK="$WORK/yoink"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
bash "$ROOT/scripts/prepare-byetunes-local-yoink.sh" "$YOINK"
cp "$ROOT/ByeTunesLocal/NodeRuntime/server-entry.ts" "$YOINK/byetunes-embedded-server.ts"

cd "$YOINK"
npx --yes esbuild@0.25.10 byetunes-embedded-server.ts \
  --bundle \
  --platform=node \
  --format=cjs \
  --target=node24 \
  --alias:@=./src \
  --outfile="$OUT/server.js"

cp LICENSE "$OUT/AGPL-3.0.txt"
cat > "$OUT/provenance.json" <<JSON
{
  "upstream": "https://github.com/yoinkify/yoink",
  "commit": "061e33ffc8d5050f828196bb78f7034f817e1e2e",
  "transport": "NodeMobile loopback",
  "youtube": false,
  "platforms": ["spotify", "deezer", "apple-music"]
}
JSON

cat > "$OUT/SOURCE.txt" <<TXT
Embedded ByeTunes-compatible Yoink runtime.
Source and reproducible patches are in the same Filza-27 repository under ByeTunesLocal/ and scripts/.
Pinned upstream: https://github.com/yoinkify/yoink
Pinned commit: 061e33ffc8d5050f828196bb78f7034f817e1e2e
TXT

test -s "$OUT/server.js"
test -s "$OUT/provenance.json"
grep -Fq '"youtube": false' "$OUT/provenance.json"
! grep -Fq 'youtube.com/watch' "$OUT/server.js"

# Host-side smoke: this proves the generated plain-Node transport boots without Next.js.
PORT=41338
BYETUNES_YOINK_PORT="$PORT" node "$OUT/server.js" > "$WORK/server.log" 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true' EXIT
for i in {1..40}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" > "$WORK/health.json"; then break; fi
  sleep 0.25
done
grep -Fq '"ok":true' "$WORK/health.json"
grep -Fq '"youtube":false' "$WORK/health.json"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" 2>/dev/null || true
trap - EXIT

echo "Built embedded ByeTunes Yoink bundle at $OUT"
