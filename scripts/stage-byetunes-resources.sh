#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEST="${1:-.theos/byetunes-resources}"

rm -rf "$DEST"
mkdir -p "$DEST"

cp "$ROOT/Assets.xcassets/AppIconImage.imageset/AppIconImage.png" "$DEST/AppIconImage.png"
cp "$ROOT/Info.plist" "$DEST/ByeTunes-Info.plist"

(
  cd "$DEST"
  shasum -a 256 AppIconImage.png ByeTunes-Info.plist > SHA256SUMS
)

echo "Staged ByeTunes metadata/lyrics resources in $DEST"
cat "$DEST/SHA256SUMS"
