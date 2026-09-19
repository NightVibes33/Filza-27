#!/bin/bash
set -euo pipefail
ROOT="${1:?AirCard source root required}"
OUT="${2:?output root required}"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
source "$HOME/.cargo/env" 2>/dev/null || true
rustup target add aarch64-apple-ios >/dev/null 2>&1 || true
(cd "$ROOT/rust-core" && cargo build --release --target aarch64-apple-ios)
mkdir -p "$OUT/lib" "$OUT/include/AirliftFFI"
cp "$ROOT/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a" "$OUT/lib/"
cp "$ROOT/rust-core/include/airlift.h" "$OUT/include/AirliftFFI/"
cat > "$OUT/include/AirliftFFI/module.modulemap" <<'EOF'
module AirliftFFI {
  header "airlift.h"
  export *
}
EOF
