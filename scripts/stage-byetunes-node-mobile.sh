#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/ByeTunesLocal/NodeRuntime/node-mobile.lock"
DEST="${1:-$ROOT/Vendor/NodeMobile}"
CACHE="${RUNNER_TEMP:-$ROOT/.build}/nodejs-mobile-ios.zip"
UNPACK="${RUNNER_TEMP:-$ROOT/.build}/nodejs-mobile-unpack"

URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$LOCK")"
SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$LOCK")"

mkdir -p "$(dirname "$CACHE")"
if [[ ! -f "$CACHE" ]]; then
  curl -fL --retry 8 --retry-all-errors --connect-timeout 30 "$URL" -o "$CACHE"
fi

ACTUAL="$(shasum -a 256 "$CACHE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA" ]]; then
  echo "NodeMobile SHA256 mismatch: expected $SHA got $ACTUAL" >&2
  rm -f "$CACHE"
  exit 1
fi

rm -rf "$UNPACK" "$DEST"
mkdir -p "$UNPACK" "$DEST"
unzip -q "$CACHE" -d "$UNPACK"

XCFRAMEWORK="$(find "$UNPACK" -type d -name 'NodeMobile.xcframework' -print -quit)"
if [[ -z "$XCFRAMEWORK" ]]; then
  echo "NodeMobile.xcframework not found in release archive" >&2
  find "$UNPACK" -maxdepth 4 -print
  exit 1
fi

python3 - "$XCFRAMEWORK" "$DEST" <<'PY'
from pathlib import Path
import plistlib, shutil, sys

xc = Path(sys.argv[1])
dest = Path(sys.argv[2])
with (xc / "Info.plist").open("rb") as fh:
    info = plistlib.load(fh)

candidate = None
for lib in info.get("AvailableLibraries", []):
    if lib.get("SupportedPlatform") != "ios":
        continue
    if lib.get("SupportedPlatformVariant"):
        continue
    if "arm64" not in lib.get("SupportedArchitectures", []):
        continue
    candidate = lib
    break

if candidate is None:
    raise SystemExit("No arm64 iphoneos NodeMobile slice found")

identifier = candidate["LibraryIdentifier"]
library_path = candidate["LibraryPath"]
src = xc / identifier / library_path
if not src.exists():
    raise SystemExit(f"NodeMobile device library missing: {src}")

dst = dest / "NodeMobile.framework"
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst)
print(f"Staged {src} -> {dst}")
PY

test -s "$DEST/NodeMobile.framework/NodeMobile"
test -s "$DEST/NodeMobile.framework/Headers/NodeMobile.h"
if command -v lipo >/dev/null 2>&1; then
  ARCHS="$(lipo -archs "$DEST/NodeMobile.framework/NodeMobile")"
  case " $ARCHS " in
    *" arm64 "*) ;;
    *) echo "NodeMobile framework lacks arm64: $ARCHS" >&2; exit 1 ;;
  esac
else
  DESC="$(file "$DEST/NodeMobile.framework/NodeMobile")"
  echo "$DESC" | grep -Eiq 'arm64|aarch64' || {
    echo "NodeMobile framework is not arm64: $DESC" >&2
    exit 1
  }
  ARCHS="arm64"
fi

echo "NodeMobile staged: $ARCHS"
