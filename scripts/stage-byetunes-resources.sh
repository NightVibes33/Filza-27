#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEST="${1:-.theos/byetunes-resources}"
YTK_ROOT="${BYETUNES_YTK_ROOT:-ThirdParty/byetunes-youtubekit/Generated}"
BYETUNES_RELEASE_IPA_URL="${BYETUNES_RELEASE_IPA_URL:-https://github.com/EduAlexxis/ByeTunes/releases/download/v2.4/ByeTunes.ipa}"
BYETUNES_RELEASE_IPA_SHA256="${BYETUNES_RELEASE_IPA_SHA256:-bd84ce18fbd80a4c738abff8e533c849ebb51d1cfe3248640c033e499681fca6}"

rm -rf "$DEST"
mkdir -p "$DEST"

# SwiftUI Image("AppIconImage") can resolve the loose PNG from the host bundle.
cp "$ROOT/Assets.xcassets/AppIconImage.imageset/AppIconImage.png" "$DEST/AppIconImage.png"

# Keep the original app plist available to the repackaging workflow so it can
# merge ByeTunes' document-import and file-sharing declarations into Filza.
cp "$ROOT/Info.plist" "$DEST/ByeTunes-Info.plist"

# The exact pre-v2.4 YouTubeKit SignatureSolver loads these by name from
# Bundle.main. They came from NightVibes33/ByeTunes commit 1a90f9e0 and must be
# present at the root of the final Filza app bundle for that upstream code path
# to work. Do not substitute generated or newer copies.
for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  test -s "$YTK_ROOT/Resources/$resource" || {
    echo "Missing pinned pre-v2.4 YouTubeKit resource: $YTK_ROOT/Resources/$resource" >&2
    exit 1
  }
  cp "$YTK_ROOT/Resources/$resource" "$DEST/$resource"
done

# Config.plist is intentionally absent from the source checkout, but upstream
# Config.swift resolves it from Bundle.main and otherwise falls back to
# https://127.0.0.1. Recover the exact v2.4 runtime configuration from the
# pinned official release IPA and validate that it is a non-loopback HTTPS URL.
TMP="$(mktemp -d /tmp/byetunes-runtime.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 --retry-delay 2 "$BYETUNES_RELEASE_IPA_URL" -o "$TMP/ByeTunes-v2.4.ipa"
echo "$BYETUNES_RELEASE_IPA_SHA256  $TMP/ByeTunes-v2.4.ipa" | shasum -a 256 -c -
mkdir -p "$TMP/release"
unzip -q "$TMP/ByeTunes-v2.4.ipa" -d "$TMP/release"
BYETUNES_APP="$(find "$TMP/release/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$BYETUNES_APP"
test -s "$BYETUNES_APP/Config.plist"
plutil -lint "$BYETUNES_APP/Config.plist" >/dev/null
python3 - "$BYETUNES_APP/Config.plist" <<'PY'
import ipaddress
import plistlib
import sys
from urllib.parse import urlparse

with open(sys.argv[1], 'rb') as f:
    config = plistlib.load(f)
raw = config.get('ByeTunesApiUrl')
if not isinstance(raw, str) or not raw.strip():
    raise SystemExit('official ByeTunes v2.4 Config.plist has no ByeTunesApiUrl')
parsed = urlparse(raw)
if parsed.scheme != 'https' or not parsed.hostname:
    raise SystemExit('official ByeTunes v2.4 ByeTunesApiUrl is not a valid HTTPS endpoint')
host = parsed.hostname.lower()
if host == 'localhost':
    raise SystemExit('official ByeTunes API endpoint unexpectedly resolves to localhost')
try:
    if ipaddress.ip_address(host).is_loopback:
        raise SystemExit('official ByeTunes API endpoint unexpectedly resolves to loopback')
except ValueError:
    pass
print('Verified official ByeTunes v2.4 runtime API configuration')
PY
cp "$BYETUNES_APP/Config.plist" "$DEST/Config.plist"

(
  cd "$DEST"
  shasum -a 256 AppIconImage.png ByeTunes-Info.plist Config.plist \
    meriyah.umd.js astring.umd.js yt_ejs_helper.js > SHA256SUMS
)

echo "Staged complete ByeTunes runtime resources in $DEST"
cat "$DEST/SHA256SUMS"
