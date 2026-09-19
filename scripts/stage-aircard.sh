#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/AirCard"
PIN="5026bf323df4f81a1b45cd107a68da164a7fd299"
rm -rf "$DEST"
git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$DEST"
git -C "$DEST" checkout --detach "$PIN"
test "$(git -C "$DEST" rev-parse HEAD)" = "$PIN"
rm -f "$DEST/ios-app/AirCardApp.swift"
printf '%s\n' "$PIN" > "$DEST/PINNED_REVISION"

# Swift emits one module for the Filza tweak; avoid basename collision with ByeTunes ContentView.swift.
mv "$DEST/ios-app/ContentView.swift" "$DEST/ios-app/AirCardContentView.swift"
