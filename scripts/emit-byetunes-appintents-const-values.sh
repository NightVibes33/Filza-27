#!/bin/bash
set -euxo pipefail

OUTPUT_ROOT="${1:-.theos/byetunes-appintents}"
SOURCE_LIST="$OUTPUT_ROOT/source-files.txt"
CONST_VALUES="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftconstvalues"
MODULE_OUT="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftmodule"
MODULE_CACHE="$OUTPUT_ROOT/module-cache"
PROTOCOL_LIST="$OUTPUT_ROOT/FilzaApplySandboxExt_const_extract_protocols.json"
ROOT="$(pwd)"

mkdir -p "$OUTPUT_ROOT" "$MODULE_CACHE"

# Match the Swift source graph in Makefile exactly. The standalone @main and
# splash owners are intentionally excluded because Filza owns the lifecycle.
{
  for file in ByeTunesEmbeddedHost.swift MondGestaltView.swift Filza3105Host.swift; do
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file"
  done
  find ThirdParty/3105/Sources -type f -name '*.swift' -print | sort | while IFS= read -r file; do
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file"
  done
  find ByeTunes/MusicManager -type f -name '*.swift' \
    ! -name 'MusicManagerApp.swift' ! -name 'SplashView.swift' -print | sort | while IFS= read -r file; do
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file"
  done
  python3 -c 'import os; print(os.path.realpath("ByeTunes/MusicManagerActivityShared/DownloadLiveActivityAttributes.swift"))'
} > "$SOURCE_LIST"

test -s "$SOURCE_LIST"
grep -Fq '/MusicManagerIntents.swift' "$SOURCE_LIST"
grep -Fq '/DownloadLiveActivityAttributes.swift' "$SOURCE_LIST"
! grep -Fq '/MusicManagerApp.swift' "$SOURCE_LIST"
! grep -Fq '/SplashView.swift' "$SOURCE_LIST"

# Swift only emits the supplementary constant-value sidecar for conformances
# named in this JSON array. These are the two AppIntents protocols implemented
# by the complete ByeTunes 2.4 source graph in MusicManagerIntents.swift.
printf '%s\n' '["AppIntents.AppIntent", "AppIntents.AppShortcutsProvider"]' > "$PROTOCOL_LIST"
test -s "$PROTOCOL_LIST"
grep -Fq 'AppIntents.AppIntent' "$PROTOCOL_LIST"
grep -Fq 'AppIntents.AppShortcutsProvider' "$PROTOCOL_LIST"

SOURCES=()
while IFS= read -r file; do
  test -s "$file"
  SOURCES+=("$file")
done < "$SOURCE_LIST"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

# Theos compiles the real module successfully but does not retain Xcode's
# supplementary constant-value output. Re-run the same source graph as a
# module-only compile so appintentsmetadataprocessor receives a real sidecar.
xcrun --sdk iphoneos swiftc \
  -emit-module \
  -emit-module-path "$MODULE_OUT" \
  -emit-const-values \
  -emit-const-values-path "$CONST_VALUES" \
  -Xfrontend -const-gather-protocols-file \
  -Xfrontend "$PROTOCOL_LIST" \
  -module-name FilzaApplySandboxExt \
  -parse-as-library \
  -swift-version 5 \
  -default-isolation MainActor \
  -target arm64-apple-ios16.0 \
  -sdk "$SDK_ROOT" \
  -module-cache-path "$MODULE_CACHE" \
  -import-objc-header "$ROOT/FilzaApplySandboxExt-Bridging-Header.h" \
  -Xcc -fmodules \
  -Xcc -fblocks \
  -Xcc -fobjc-arc \
  -Xcc -I"$ROOT/compat" \
  -Xcc -I"$ROOT" \
  -Xcc -I"$ROOT/XPF/src" \
  -Xcc -I"$ROOT/XPF/external/ChOma/include" \
  -Xcc -I"$ROOT/Vendor/idevice/include" \
  -Xcc -I"$ROOT/ThirdParty/bad_query/bad_query" \
  -Xcc -I"$ROOT/ThirdParty/3105/Sources" \
  -Xcc -I"$SDK_ROOT/usr/include/libxml2" \
  "${SOURCES[@]}"

test -s "$MODULE_OUT"
test -s "$CONST_VALUES"
echo "Emitted $CONST_VALUES from ${#SOURCES[@]} embedded Swift sources using $PROTOCOL_LIST"
