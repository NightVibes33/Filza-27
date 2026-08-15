#!/usr/bin/env bash
set -euo pipefail

# Restore the exact vendored YouTubeKit source tree used by the last known-good
# pre-v2.4 Filza/ByeTunes integration. Keep it outside the v2.4 submodule so the
# current ByeTunes source, All Sources routing, and metadata editor stay intact.
SOURCE_REPO="NightVibes33/ByeTunes"
SOURCE_COMMIT="1a90f9e0f2b1a1787b208809ad2373f5c52175c8"
ROOT="ThirdParty/byetunes-youtubekit"
GEN="$ROOT/Generated"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-byetunes-youtubekit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 \
  "https://codeload.github.com/${SOURCE_REPO}/tar.gz/${SOURCE_COMMIT}" \
  -o "$TMP/byetunes.tar.gz"
mkdir -p "$TMP/src"
tar -xzf "$TMP/byetunes.tar.gz" -C "$TMP/src" --strip-components=1

SRC="$TMP/src/MusicManager/YouTubeKit"
test -d "$SRC" || { echo "Pinned pre-v2.4 YouTubeKit tree is missing" >&2; exit 1; }
test -f "$SRC/YouTube.swift"
test -f "$SRC/InnerTube.swift"
test -f "$SRC/Extraction.swift"
test -f "$SRC/Models/YouTubeMetadata.swift"
test -f "$SRC/Resources/meriyah.umd.js"
test -f "$SRC/Resources/astring.umd.js"
test -f "$SRC/Resources/yt_ejs_helper.js"

rm -rf "$GEN"
mkdir -p "$GEN"
cp -R "$SRC"/. "$GEN"/

cat > "$ROOT/PINNED.txt" <<EOF
repo=$SOURCE_REPO
commit=$SOURCE_COMMIT
source=MusicManager/YouTubeKit
EOF

SWIFT_COUNT="$(find "$GEN" -type f -name '*.swift' | wc -l | tr -d ' ')"
test "$SWIFT_COUNT" -eq 28 || {
  echo "Pinned YouTubeKit source count changed: expected 28, got $SWIFT_COUNT" >&2
  exit 1
}

grep -Fq 'public class YouTube' "$GEN/YouTube.swift"
grep -Fq 'var videoDetails:' "$GEN/YouTube.swift"
grep -Fq 'class SignatureSolver' "$GEN/SignatureSolver.swift"

echo "Staged exact pre-v2.4 ByeTunes YouTubeKit ${SOURCE_COMMIT} (${SWIFT_COUNT} Swift files)"
