#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEST="${1:-.theos/byetunes-resources}"
LOCAL_API_URL="${BYETUNES_LOCAL_API_URL:-http://127.0.0.1:41337}"

rm -rf "$DEST"
mkdir -p "$DEST"

cp "$ROOT/Assets.xcassets/AppIconImage.imageset/AppIconImage.png" "$DEST/AppIconImage.png"
cp "$ROOT/Info.plist" "$DEST/ByeTunes-Info.plist"

python3 - "$DEST/Config.plist" "$LOCAL_API_URL" <<'PY'
import plistlib
import sys
from urllib.parse import urlparse
path, raw = sys.argv[1], sys.argv[2]
parsed = urlparse(raw)
if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost") or parsed.port != 41337:
    raise SystemExit(f"refusing non-loopback ByeTunes local API URL: {raw!r}")
with open(path, "wb") as fh:
    plistlib.dump({"ByeTunesApiUrl": raw}, fh, sort_keys=False)
print(f"Staged self-hosted ByeTunes API configuration: {raw}")
PY

plutil -lint "$DEST/Config.plist" >/dev/null
test "$(plutil -extract ByeTunesApiUrl raw -o - "$DEST/Config.plist")" = "$LOCAL_API_URL"

(
  cd "$DEST"
  shasum -a 256 AppIconImage.png ByeTunes-Info.plist Config.plist > SHA256SUMS
)

echo "Staged complete self-hosted ByeTunes runtime resources in $DEST"
cat "$DEST/SHA256SUMS"
