#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/ByeTunesLocal/iSH/ish.lock"
DEST="${1:-$ROOT/Vendor/iSH}"
if [[ "$DEST" != /* ]]; then
  DEST="$ROOT/$DEST"
fi
SRC="$DEST/src"
BUILD="$DEST/build"
OBJ="$DEST/obj"
LIB="$DEST/lib"
LICENSES="$DEST/licenses"

COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$LOCK")"
REPO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$LOCK")"

if [[ -s "$LIB/libish.a" && -s "$LIB/libish_emu.a" && -s "$LIB/libfakefs.a" && -f "$DEST/provenance.json" ]]; then
  EXISTING="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' "$DEST/provenance.json" 2>/dev/null || true)"
  if [[ "$EXISTING" == "$COMMIT" ]]; then
    echo "Official iSH already staged at $COMMIT"
    exit 0
  fi
fi

rm -rf "$DEST"
mkdir -p "$DEST" "$LIB" "$LICENSES"

git clone --filter=blob:none "$REPO" "$SRC"
git -C "$SRC" checkout --detach "$COMMIT"
git -C "$SRC" submodule update --init --recursive

ACTUAL="$(git -C "$SRC" rev-parse HEAD)"
[[ "$ACTUAL" == "$COMMIT" ]] || { echo "iSH pin mismatch: $ACTUAL" >&2; exit 1; }

if command -v brew >/dev/null 2>&1; then
  LLVM_BIN="$(brew --prefix llvm 2>/dev/null)/bin"
  LLD_BIN="$(brew --prefix lld 2>/dev/null)/bin"
  if [[ -d "$LLD_BIN" ]]; then export PATH="$LLD_BIN:$PATH"; fi
  if [[ -d "$LLVM_BIN" ]]; then export PATH="$LLVM_BIN:$PATH"; fi
fi
command -v ld.lld >/dev/null 2>&1 || { echo "Official iSH requires Homebrew lld (brew install lld)" >&2; exit 1; }
ld.lld --version

for target in libish libish_emu libfakefs; do
  xcodebuild \
    -project "$SRC/iSH.xcodeproj" \
    -target "$target" \
    -configuration Release \
    -sdk iphoneos \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    CODE_SIGNING_ALLOWED=NO \
    SYMROOT="$BUILD" \
    OBJROOT="$OBJ" \
    build
done

copy_product() {
  local name="$1"
  local found
  found="$(find "$BUILD" -type f -name "$name" -print -quit)"
  [[ -n "$found" ]] || { echo "Missing official iSH product $name" >&2; find "$BUILD" -maxdepth 4 -type f -print; exit 1; }
  cp "$found" "$LIB/$name"
}

copy_product libish.a
copy_product libish_emu.a
copy_product libfakefs.a

cp "$SRC/LICENSE.md" "$LICENSES/LICENSE.md"
cp "$SRC/LICENSE.IOS" "$LICENSES/LICENSE.IOS"

for archive in "$LIB/libish.a" "$LIB/libish_emu.a" "$LIB/libfakefs.a"; do
  test -s "$archive"
  ARCHS_OUT="$(lipo -archs "$archive")"
  case " $ARCHS_OUT " in
    *" arm64 "*) ;;
    *) echo "$archive is not arm64: $ARCHS_OUT" >&2; exit 1 ;;
  esac
done

python3 - "$DEST/provenance.json" "$COMMIT" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({
        "repository":"https://github.com/ish-app/ish",
        "commit":sys.argv[2],
        "targets":["libish","libish_emu","libfakefs"],
        "architecture":"arm64",
        "uiIncluded":False
    }, fh, indent=2, sort_keys=True)
PY

echo "Staged official iSH static libraries at $DEST"
