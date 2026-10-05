#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEST="${1:-.theos/byetunes-resources}"

rm -rf "$DEST"
mkdir -p "$DEST"

# SwiftUI Image("AppIconImage") can resolve the loose PNG from the host bundle.
cp "$ROOT/Assets.xcassets/AppIconImage.imageset/AppIconImage.png" "$DEST/AppIconImage.png"

# Keep the original app plist available to the repackaging workflow so it can
# merge ByeTunes' document-import and file-sharing declarations into Filza.
cp "$ROOT/Info.plist" "$DEST/ByeTunes-Info.plist"

# Do not extract or stage Config.plist from a ByeTunes release IPA. Filza only
# consumes ByeTunes metadata functionality; upstream server configuration must
# not be copied into Filza's source tree or packaged resources.

(
  cd "$DEST"
  shasum -a 256 AppIconImage.png ByeTunes-Info.plist > SHA256SUMS
)

echo "Staged ByeTunes app resources in $DEST"
cat "$DEST/SHA256SUMS"
