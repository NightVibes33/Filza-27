#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/ByeTunesLocal/Upstream/yoink.lock"
PATCHER="$ROOT/scripts/apply-byetunes-local-yoink-patch.py"
DEST="${1:-$ROOT/.build/byetunes-local-yoink}"

REPO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$LOCK")"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$LOCK")"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
git clone --filter=blob:none --no-checkout "$REPO" "$DEST"
git -C "$DEST" checkout --detach "$COMMIT"

ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$ACTUAL" != "$COMMIT" ]]; then
  echo "Yoink pin mismatch: expected $COMMIT got $ACTUAL" >&2
  exit 1
fi

python3 - "$LOCK" "$DEST" <<'PY'
import json, subprocess, sys
lock=json.load(open(sys.argv[1]))
root=sys.argv[2]
for path, expected in lock["expectedGitBlobs"].items():
    actual=subprocess.check_output(["git","-C",root,"rev-parse",f"HEAD:{path}"],text=True).strip()
    if actual != expected:
        raise SystemExit(f"Yoink blob mismatch for {path}: expected {expected}, got {actual}")
print("Pinned Yoink blob verification passed")
PY

python3 "$PATCHER" "$DEST"

grep -Fq '"spotify" | "apple-music" | "youtube" | "deezer"' "$DEST/src/lib/spotify.ts"
grep -Fq 'url.includes("deezer.com") || url.includes("deezer.page.link") || url.includes("link.deezer.com")' "$DEST/src/lib/spotify.ts"
grep -Fq 'resolveDirectDeezerTrack' "$DEST/src/lib/resolve-track.ts"
grep -Fq 'paste a spotify, deezer, or apple music link' "$DEST/src/app/api/download/route.ts"
grep -Fq 'paste a spotify, deezer, or apple music link' "$DEST/src/app/api/metadata/route.ts"

echo "Prepared patched Yoink at $DEST"
git -C "$DEST" diff --check
