#!/bin/bash
set -euo pipefail

# This script is intentionally kept independent from the runtime parity patches;
# changing/retrying AppIntents packaging must not alter the linked ByeTunes code.
OUTPUT_ROOT="${1:-.theos/byetunes-appintents}"
SOURCE_LIST="$OUTPUT_ROOT/source-files.txt"
CONST_LIST="$OUTPUT_ROOT/swift-const-values.txt"
CONST_VALUES="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftconstvalues"
METADATA_OUT="$OUTPUT_ROOT/Metadata.appintents"
PROCESSOR_STDERR="$OUTPUT_ROOT/appintentsmetadataprocessor.stderr"
MODULE_NAME="FilzaApplySandboxExt"
DEPLOYMENT_TARGET="16.0"
TARGET_TRIPLE="arm64-apple-ios16.0"

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT"

echo "Generating AppIntents constant values for embedded ByeTunes module..."
bash scripts/emit-byetunes-appintents-const-values.sh "$OUTPUT_ROOT"
printf '%s\n' "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CONST_VALUES")" > "$CONST_LIST"
test -s "$SOURCE_LIST"
test -s "$CONST_LIST"
test -s "$CONST_VALUES"

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TOOLCHAIN_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/{print $3}')"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"

test -x "$PROCESSOR"
test -d "$TOOLCHAIN_DIR"
test -d "$SDK_ROOT"
test -n "$XCODE_BUILD_VERSION"

rm -f "$PROCESSOR_STDERR"
echo "Running appintentsmetadataprocessor for module $MODULE_NAME..."
if ! "$PROCESSOR" \
  --output "$METADATA_OUT" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name "$MODULE_NAME" \
  --sdk-root "$SDK_ROOT" \
  --xcode-version "$XCODE_BUILD_VERSION" \
  --platform-family iOS \
  --deployment-target "$DEPLOYMENT_TARGET" \
  --target-triple "$TARGET_TRIPLE" \
  --source-file-list "$SOURCE_LIST" \
  --swift-const-vals-list "$CONST_LIST" \
  --force \
  --force-metadata-output 2>"$PROCESSOR_STDERR"; then
  echo "ERROR: appintentsmetadataprocessor failed. Diagnostics:"
  cat "$PROCESSOR_STDERR"
  exit 1
fi

if test -s "$PROCESSOR_STDERR"; then
  echo "appintentsmetadataprocessor diagnostics:"
  cat "$PROCESSOR_STDERR"
fi

test -d "$METADATA_OUT"
FILE_COUNT="$(find "$METADATA_OUT" -type f | wc -l | tr -d ' ')"
test "$FILE_COUNT" -gt 0

echo "Generated $METADATA_OUT with $FILE_COUNT files"
find "$METADATA_OUT" -maxdepth 3 -type f -print -exec shasum -a 256 {} \;
