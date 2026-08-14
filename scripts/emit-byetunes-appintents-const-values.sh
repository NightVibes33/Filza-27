#!/bin/bash
set -euxo pipefail

OUTPUT_ROOT="${1:-.theos/byetunes-appintents}"
SOURCE_LIST="$OUTPUT_ROOT/source-files.txt"
CONST_VALUES="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftconstvalues"
OBJECT_OUT="$OUTPUT_ROOT/MusicManagerIntents.o"
MODULE_CACHE="$OUTPUT_ROOT/module-cache"
PROTOCOL_LIST="$OUTPUT_ROOT/FilzaApplySandboxExt_const_extract_protocols.json"
ROOT="$(pwd)"
INTENTS_SOURCE="$(python3 -c 'import os; print(os.path.realpath("ByeTunes/MusicManager/MusicManagerIntents.swift"))')"

mkdir -p "$OUTPUT_ROOT" "$MODULE_CACHE"

# Match the Swift source graph in Makefile exactly. The standalone @main and
# splash owners are intentionally excluded because Filza owns the lifecycle.
{
  for file in ByeTunesEmbeddedHost.swift ByeTunesMetadataCompat.swift MondGestaltView.swift Filza3105Host.swift; do
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
grep -Fq '/ByeTunesMetadataCompat.swift' "$SOURCE_LIST"
grep -Fq '/MusicManagerIntents.swift' "$SOURCE_LIST"
grep -Fq '/DownloadLiveActivityAttributes.swift' "$SOURCE_LIST"
! grep -Fq '/MusicManagerApp.swift' "$SOURCE_LIST"
! grep -Fq '/SplashView.swift' "$SOURCE_LIST"

# Swift only emits the supplementary constant-value sidecar for conformances
# whose unqualified declaration names appear in this JSON array. These are the
# two protocols implemented by the complete ByeTunes 2.4 intents source.
printf '%s\n' '["AppIntent", "AppShortcutsProvider"]' > "$PROTOCOL_LIST"
test -s "$PROTOCOL_LIST"
grep -Fq '"AppIntent"' "$PROTOCOL_LIST"
grep -Fq '"AppShortcutsProvider"' "$PROTOCOL_LIST"

SOURCES=()
FRONTEND_SOURCES=()
while IFS= read -r file; do
  test -s "$file"
  SOURCES+=("$file")
  if test "$file" = "$INTENTS_SOURCE"; then
    FRONTEND_SOURCES+=(-primary-file "$file")
  else
    FRONTEND_SOURCES+=("$file")
  fi
done < "$SOURCE_LIST"
test "$(printf '%s\n' "${FRONTEND_SOURCES[@]}" | grep -Fc -- '-primary-file')" = 1

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

# Match Xcode's per-primary Swift frontend job: compile the intents source as
# the primary file while making the complete embedded module graph visible.
# Calling swift-frontend directly prevents swiftc's module-only driver action
# from discarding the supplementary constant-values output.
xcrun --sdk iphoneos swift-frontend \
  -frontend \
  -c \
  "${FRONTEND_SOURCES[@]}" \
  -emit-const-values-path "$CONST_VALUES" \
  -const-gather-protocols-file "$PROTOCOL_LIST" \
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
  -o "$OBJECT_OUT"

test -s "$OBJECT_OUT"
test -s "$CONST_VALUES"
echo "Emitted $CONST_VALUES from ${#SOURCES[@]} embedded Swift sources using $PROTOCOL_LIST"
