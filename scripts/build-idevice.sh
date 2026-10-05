#!/bin/bash
set -euxo pipefail

IDEVICE_COMMIT="37ee77cf713f483551f3cf33ea8b2087a40058ca"
OUTPUT_ROOT="${1:-$PWD/Vendor/idevice}"
SOURCE_ROOT="${RUNNER_TEMP:-/tmp}/filzaslop-idevice-src"
TARGET_TRIPLE="aarch64-apple-ios"

rm -rf "$SOURCE_ROOT" "$OUTPUT_ROOT"
git clone --filter=blob:none https://github.com/jkcoxson/idevice.git "$SOURCE_ROOT"
git -C "$SOURCE_ROOT" checkout --detach "$IDEVICE_COMMIT"
test "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$IDEVICE_COMMIT"

rustc --version
cargo --version
rustup target add "$TARGET_TRIPLE"

export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$(xcrun --sdk iphoneos --find clang)"

cd "$SOURCE_ROOT"

# ByeTunes normally owns its process, so idevice's logger can safely install a
# global tracing subscriber. Embedded inside Filza it does not own the process;
# another subscriber may already exist. tracing_subscriber::init() panics in
# that case and aborts immediately when ContentView constructs DeviceManager.
# Keep the exact pinned idevice source but make global logger registration
# non-fatal for this embedded build. All transport APIs remain unchanged.
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
! grep -Fq 'subscriber.init();' "$LOGGING_RS"

# The complete ByeTunes DeviceManager uses substantially more than AFC: it
# opens heartbeat, lockdown/notification-proxy and RSD/CoreDevice paths too.
# Build idevice-ffi with its normal default feature set, matching ByeTunes'
# own successful unsigned-device workflow instead of the old reduced bridge's
# AFC-only feature subset.
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

file "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/lib/libidevice_ffi.a"
test -s "$OUTPUT_ROOT/include/idevice.h"
shasum -a 256 "$OUTPUT_ROOT/lib/libidevice_ffi.a"
printf '%s\n' "$IDEVICE_COMMIT" > "$OUTPUT_ROOT/COMMIT"
