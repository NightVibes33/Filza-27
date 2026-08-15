#!/usr/bin/env bash
set -euo pipefail
set -x

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDEVICE_REPO="https://github.com/jkcoxson/idevice.git"
IDEVICE_COMMIT="${IDEVICE_COMMIT:-37ee77cf713f483551f3cf33ea8b2087a40058ca}"
RUST_TARGET="aarch64-apple-ios-sim"
WORK_DIR="$ROOT/.sim/idevice"
DEST_DIR="$ROOT/ByeTunes/MusicManager"
ARTIFACT_DIR="$ROOT/.sim/artifacts"

mkdir -p "$ROOT/.sim" "$ARTIFACT_DIR"
rm -rf "$WORK_DIR"
git clone --filter=blob:none "$IDEVICE_REPO" "$WORK_DIR"
git -C "$WORK_DIR" checkout --detach "$IDEVICE_COMMIT"
test "$(git -C "$WORK_DIR" rev-parse HEAD)" = "$IDEVICE_COMMIT"

command -v cargo
command -v rustup
rustup target add "$RUST_TARGET"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export SDKROOT="$SDK_PATH"
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK_PATH"
export RUSTFLAGS="-C link-arg=-L${SDK_PATH}/usr/lib"
export IPHONEOS_DEPLOYMENT_TARGET=16.0

# This uses idevice's real FFI crate. Its own Xcode helper maps an arm64
# iphonesimulator build to aarch64-apple-ios-sim, so this is not a stub layer.
(
  cd "$WORK_DIR/ffi"
  cargo build --release --target "$RUST_TARGET"
)

HEADER="$WORK_DIR/ffi/idevice.h"
LIB="$WORK_DIR/target/$RUST_TARGET/release/libidevice_ffi.a"
test -s "$HEADER"
test -s "$LIB"

grep -Fq 'IdeviceFfiError' "$HEADER"
grep -Fq 'idevice_init_logger' "$HEADER"
nm -gU "$LIB" | grep -q 'idevice_init_logger'

cp "$HEADER" "$DEST_DIR/idevice.h"
cp "$LIB" "$DEST_DIR/libidevice_ffi.a"
cat > "$DEST_DIR/Bridging-Header.h" <<'EOF'
#ifndef BYETUNES_SIMULATOR_BRIDGING_HEADER_H
#define BYETUNES_SIMULATOR_BRIDGING_HEADER_H
#include "idevice.h"
#endif
EOF

lipo -info "$DEST_DIR/libidevice_ffi.a" | tee "$ARTIFACT_DIR/idevice-simulator-lipo.txt"
printf 'idevice_commit=%s\nrust_target=%s\nsdk=%s\n' \
  "$IDEVICE_COMMIT" "$RUST_TARGET" "$SDK_PATH" \
  | tee "$ARTIFACT_DIR/idevice-simulator-build.txt"

# Prove the generated header and library surface expected by ByeTunes exist.
grep -E 'IdeviceFfiError|idevice_init_logger|idevice_provider_free|rsd_handshake_free|adapter_close' \
  "$DEST_DIR/idevice.h" > "$ARTIFACT_DIR/idevice-required-symbols.txt"
