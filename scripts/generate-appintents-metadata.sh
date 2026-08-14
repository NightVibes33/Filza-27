#!/bin/bash
set -euxo pipefail

OUTPUT_ROOT="${1:-.theos/byetunes-appintents}"
SOURCE_LIST="$OUTPUT_ROOT/source-files.txt"
CONST_LIST="$OUTPUT_ROOT/swift-const-values.txt"
CONST_VALUES="$OUTPUT_ROOT/FilzaApplySandboxExt.swiftconstvalues"
METADATA_OUT="$OUTPUT_ROOT/Metadata.appintents"
MODULE_NAME="FilzaApplySandboxExt"
DEPLOYMENT_TARGET="16.0"
TARGET_TRIPLE="arm64-apple-ios16.0"

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT"

# Generate the supplementary constant-value sidecar from the exact Swift graph
# compiled into FilzaApplySandboxExt. Do not substitute standalone ByeTunes.
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

"$PROCESSOR" \
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
  --force-metadata-output

test -d "$METADATA_OUT"
FILE_COUNT="$(find "$METADATA_OUT" -type f | wc -l | tr -d ' ')"
test "$FILE_COUNT" -gt 0

echo "Generated $METADATA_OUT with $FILE_COUNT files"
find "$METADATA_OUT" -type f -maxdepth 3 -print -exec shasum -a 256 {} \;
