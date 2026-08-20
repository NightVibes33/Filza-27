#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
UPSTREAM="$ROOT/Upstream"
PINNED="$ROOT/PINNED.txt"
RESOURCES="$ROOT/Resources"
BUNDLE="$RESOURCES/MondEmbedded.bundle"
PROJECT_META="$ROOT/UpstreamProject.pbxproj"

test -s "$PINNED" || { echo "Missing pinned Mond manifest" >&2; exit 1; }
MOND_COMMIT="$(awk -F= '$1 == "mond" { print $2 }' "$PINNED")"
test -n "$MOND_COMMIT"

rm -rf "$RESOURCES"
mkdir -p "$BUNDLE"

# Preserve and validate the app-target metadata that is not part of the mond/
# source directory copied into Upstream/. This is the metadata standalone Mond
# normally receives from Xcode's target configuration.
curl -fL --retry 3 --retry-delay 2 \
  "https://raw.githubusercontent.com/rooootdev/mond/${MOND_COMMIT}/mond.xcodeproj/project.pbxproj" \
  -o "$PROJECT_META"

grep -Fq 'INFOPLIST_KEY_CFBundleDisplayName = mond;' "$PROJECT_META"
grep -Fq 'MARKETING_VERSION = 2.2;' "$PROJECT_META"
grep -Fq 'CURRENT_PROJECT_VERSION = 1;' "$PROJECT_META"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.roooot.mond;' "$PROJECT_META"
grep -Fq 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;' "$PROJECT_META"

# Use the exact pinned upstream artwork file rather than Filza's app icon.
curl -fL --retry 3 --retry-delay 2 \
  "https://raw.githubusercontent.com/rooootdev/mond/${MOND_COMMIT}/mond.png" \
  -o "$BUNDLE/MondEmbeddedIcon.png"
test -s "$BUNDLE/MondEmbeddedIcon.png"
file "$BUNDLE/MondEmbeddedIcon.png" | grep -Fq 'PNG image data'

cat > "$BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>mond</string>
    <key>CFBundleName</key>
    <string>mond</string>
    <key>CFBundleIdentifier</key>
    <string>com.roooot.mond</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>MondEmbeddedIcon</string>
            </array>
        </dict>
    </dict>
</dict>
</plist>
PLIST

plutil -lint "$BUNDLE/Info.plist"
test "$(plutil -extract CFBundleDisplayName raw -o - "$BUNDLE/Info.plist")" = "mond"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE/Info.plist")" = "2.2"
test "$(plutil -extract CFBundleIdentifier raw -o - "$BUNDLE/Info.plist")" = "com.roooot.mond"

echo "Staged Mond 2.2 embedded resource bundle from pinned commit ${MOND_COMMIT}"
