#!/bin/bash
set -euo pipefail

OUTPUT_ROOT="${1:-.theos/byetunes-appintents}"
SOURCE_LIST="$OUTPUT_ROOT/source-files.txt"
CONST_VALUES="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftconstvalues"
OBJECT_OUT="$OUTPUT_ROOT/MusicManagerIntents.o"
MODULE_CACHE="$OUTPUT_ROOT/module-cache"
PROTOCOL_LIST="$OUTPUT_ROOT/FilzaApplySandboxExt_const_extract_protocols.json"
FRONTEND_STDERR="$OUTPUT_ROOT/swift-frontend.stderr"
ROOT="$(pwd)"
INTENTS_SOURCE="$(python3 -c 'import os; print(os.path.realpath("ByeTunes/MusicManager/MusicManagerIntents.swift"))')"

mkdir -p "$OUTPUT_ROOT" "$MODULE_CACHE"

realpath_source() {
  local file="$1"
  if ! test -s "$file"; then
    echo "ERROR: AppIntents source graph is missing required Swift source: $file" >&2
    exit 1
  fi
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file"
}

append_swift_tree() {
  local directory="$1"
  if ! test -d "$directory"; then
    echo "ERROR: AppIntents source graph is missing required Swift source directory: $directory" >&2
    exit 1
  fi
  while IFS= read -r file; do
    realpath_source "$file"
  done < <(find "$directory" -type f -name '*.swift' -print | sort)
}

# Keep the AppIntents extraction module aligned with the Swift graph that is
# actually linked into FilzaApplySandboxExt. The standalone ByeTunes @main and
# splash owners remain excluded because Filza owns UIApplication lifecycle.
#
# Mond 2.1 and the pinned pre-v2.4 YouTubeKit are staged by the normal Theos
# pre-build hooks. The metadata pass runs after the successful arm64 build, so
# those generated trees must be present and must participate in this frontend
# invocation just as they do in the real module build.
{
  for file in \
    ByeTunesEmbeddedHost.swift \
    ByeTunesMetadataCompat.swift \
    ByeTunesDownloadParityCompat.swift \
    FilzaMondCurrentHost.swift \
    Filza3105Host.swift; do
    realpath_source "$file"
  done

  append_swift_tree ThirdParty/mond-current/Generated/Mond
  append_swift_tree ThirdParty/mond-current/Generated/PartyUI
  append_swift_tree ThirdParty/mond-current/Generated/ZIPFoundation
  append_swift_tree ThirdParty/3105/Sources

  find ByeTunes/MusicManager -type f -name '*.swift' \
    ! -name 'MusicManagerApp.swift' ! -name 'SplashView.swift' -print | sort | while IFS= read -r file; do
    realpath_source "$file"
  done

  realpath_source ByeTunes/MusicManagerActivityShared/DownloadLiveActivityAttributes.swift
  append_swift_tree ThirdParty/byetunes-youtubekit/Generated
} > "$SOURCE_LIST"

test -s "$SOURCE_LIST"
grep -Fq '/ByeTunesMetadataCompat.swift' "$SOURCE_LIST"
grep -Fq '/ByeTunesDownloadParityCompat.swift' "$SOURCE_LIST"
grep -Fq '/FilzaMondCurrentHost.swift' "$SOURCE_LIST"
grep -Fq '/mond-current/Generated/Mond/views_app_ContentView.swift' "$SOURCE_LIST"
grep -Fq '/mond-current/Generated/PartyUI/Containers_TerminalPlatter.swift' "$SOURCE_LIST"
grep -Fq '/mond-current/Generated/ZIPFoundation/Archive.swift' "$SOURCE_LIST"
grep -Fq '/MusicManagerIntents.swift' "$SOURCE_LIST"
grep -Fq '/DownloadLiveActivityAttributes.swift' "$SOURCE_LIST"
grep -Fq '/byetunes-youtubekit/Generated/YouTube.swift' "$SOURCE_LIST"
! grep -Fq '/MondGestaltView.swift' "$SOURCE_LIST"
! grep -Fq '/MusicManagerApp.swift' "$SOURCE_LIST"
! grep -Fq '/SplashView.swift' "$SOURCE_LIST"

printf '%s\n' '["AppIntent", "AppShortcutsProvider"]' > "$PROTOCOL_LIST"
test -s "$PROTOCOL_LIST"

SOURCES=()
FRONTEND_SOURCES=()
while IFS= read -r file; do
  if ! test -s "$file"; then
    echo "ERROR: AppIntents source list contains a missing source: $file" >&2
    exit 1
  fi
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

rm -f "$FRONTEND_STDERR"
echo "AppIntents const extraction: compiling MusicManagerIntents.swift as the single primary file across ${#SOURCES[@]} embedded Swift sources"

if ! xcrun --sdk iphoneos swift-frontend \
  -frontend \
  -c \
  "${FRONTEND_SOURCES[@]}" \
  -emit-const-values-path "$CONST_VALUES" \
  -const-gather-protocols-file "$PROTOCOL_LIST" \
  -module-name FilzaApplySandboxExt \
  -parse-as-library \
  -swift-version 5 \
  -default-isolation MainActor \
  -solver-expression-time-threshold=300 \
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
  -Xcc -I"$ROOT/ThirdParty/mond-current/Generated" \
  -Xcc -I"$SDK_ROOT/usr/include/libxml2" \
  -o "$OBJECT_OUT" 2>"$FRONTEND_STDERR"; then
  echo "ERROR: Swift AppIntents constant-value extraction failed. Compiler diagnostics:"
  cat "$FRONTEND_STDERR"
  exit 1
fi

if test -s "$FRONTEND_STDERR"; then
  echo "Swift AppIntents constant-value extraction diagnostics:"
  cat "$FRONTEND_STDERR"
fi

test -s "$OBJECT_OUT"
test -s "$CONST_VALUES"
echo "Emitted $CONST_VALUES from ${#SOURCES[@]} embedded Swift sources using $PROTOCOL_LIST"
