#!/bin/bash
set -euxo pipefail

IDEVICE_COMMIT="37ee77cf713f483551f3cf33ea8b2087a40058ca"
OUTPUT_ROOT="${1:-$PWD/Vendor/idevice-simulator}"
SOURCE_ROOT="${RUNNER_TEMP:-/tmp}/filzaslop-idevice-simulator-src"
TARGET_TRIPLE="aarch64-apple-ios-sim"

rm -rf "$SOURCE_ROOT" "$OUTPUT_ROOT"
git clone --filter=blob:none https://github.com/jkcoxson/idevice.git "$SOURCE_ROOT"
git -C "$SOURCE_ROOT" checkout --detach "$IDEVICE_COMMIT"
test "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$IDEVICE_COMMIT"

rustc --version
cargo --version
rustup target add "$TARGET_TRIPLE"

export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER="$(xcrun --sdk iphonesimulator --find clang)"

cd "$SOURCE_ROOT"

LOGGING_RS="$SOURCE_ROOT/ffi/src/logging.rs"
test -f "$LOGGING_RS"
python3 - "$LOGGING_RS" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = "        subscriber.init();"
new = "        let _ = subscriber.try_init();"
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one idevice logger init call, found {count}")
path.write_text(text.replace(old, new, 1))
PY

grep -Fq 'let _ = subscriber.try_init();' "$LOGGING_RS"

cargo build \
  --manifest-path ffi/Cargo.toml \
  --release \
  --locked \
  --target "$TARGET_TRIPLE"

LIBRARY="$SOURCE_ROOT/target/$TARGET_TRIPLE/release/libidevice_ffi.a"
test -f "$LIBRARY"
mkdir -p "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/include"
cp "$LIBRARY" "$OUTPUT_ROOT/lib/libidevice_ffi.a"
cp "$SOURCE_ROOT/ffi/idevice.h" "$OUTPUT_ROOT/include/idevice.h"
cat > "$OUTPUT_ROOT/include/ByeTunesSimulatorBridging.h" <<'EOF'
#pragma once
#include "idevice.h"
EOF

file "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/include/idevice.h"
test -s "$OUTPUT_ROOT/include/ByeTunesSimulatorBridging.h"
shasum -a 256 "$OUTPUT_ROOT/lib/libidevice_ffi.a"
printf '%s\n' "$IDEVICE_COMMIT" > "$OUTPUT_ROOT/COMMIT"
