#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEST="${1:-.theos/byetunes-resources}"

rm -rf "$DEST"
mkdir -p "$DEST"

# SignatureSolver uses Bundle.main for these exact filenames.
cp "$ROOT/YouTubeKit/Resources/meriyah.umd.js" "$DEST/meriyah.umd.js"
cp "$ROOT/YouTubeKit/Resources/astring.umd.js" "$DEST/astring.umd.js"
cp "$ROOT/YouTubeKit/Resources/yt_ejs_helper.js" "$DEST/yt_ejs_helper.js"

# SwiftUI Image("AppIconImage") can resolve the loose PNG from the host bundle.
cp "$ROOT/Assets.xcassets/AppIconImage.imageset/AppIconImage.png" "$DEST/AppIconImage.png"

# Keep the original app plist available to the repackaging workflow so it can
# merge ByeTunes' document-import and file-sharing declarations into Filza.
cp "$ROOT/Info.plist" "$DEST/ByeTunes-Info.plist"

(
  cd "$DEST"
  shasum -a 256 meriyah.umd.js astring.umd.js yt_ejs_helper.js AppIconImage.png ByeTunes-Info.plist > SHA256SUMS
)

echo "Staged complete ByeTunes runtime resources in $DEST"
cat "$DEST/SHA256SUMS"
