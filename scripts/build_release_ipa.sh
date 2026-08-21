#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 <base-unsigned.ipa> <output.ipa> [MCMIdentifiers.plist]" >&2
  exit 64
fi

BASE_IPA="${1:A}"
OUTPUT_IPA="${2:A}"
CATALOG="${3:-}"
if [[ -n "$CATALOG" ]]; then
  CATALOG="${CATALOG:A}"
fi

REPO_ROOT="${0:A:h:h}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

[[ -f "$BASE_IPA" ]] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
if [[ -n "$CATALOG" ]]; then
  [[ -f "$CATALOG" ]] || { echo "catalog not found: $CATALOG" >&2; exit 66; }
  plutil -lint "$CATALOG" >/dev/null
  plutil -extract AppData xml1 -o /dev/null "$CATALOG"
fi

cd "$REPO_ROOT"
make clean
make package FINALPACKAGE=1

DYLIB="$REPO_ROOT/.theos/obj/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || { echo "built dylib not found: $DYLIB" >&2; exit 70; }

# Keep the standalone release path identical to the verified Actions package:
# stage v2.4 runtime files plus the exact pre-v2.4 YouTubeKit JS resources that
# SignatureSolver resolves from Bundle.main.
bash "$REPO_ROOT/scripts/stage-byetunes-resources.sh" "$REPO_ROOT/.theos/byetunes-resources"
for resource in AppIconImage.png ByeTunes-Info.plist Config.plist meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  [[ -s "$REPO_ROOT/.theos/byetunes-resources/$resource" ]] || {
    echo "staged ByeTunes resource missing: $resource" >&2
    exit 70
  }
done

STAGE_ROOT="$(mktemp -d /tmp/FilzaSlop-release.XXXXXX)"
trap 'trash "$STAGE_ROOT"' EXIT
unzip -q "$BASE_IPA" -d "$STAGE_ROOT/stage"

APP="$(find "$STAGE_ROOT/stage/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Payload app not found" >&2; exit 65; }

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist")"
[[ "$BUNDLE_ID" == "com.apple.mobile.MobileHouseArrest" ]] || {
  echo "unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 65
}

if codesign -d "$APP" >/dev/null 2>&1; then
  echo "base app is signed; use an unsigned base IPA" >&2
  exit 65
fi

cp "$DYLIB" "$APP/Frameworks/FilzaApplySandboxExt.dylib"
codesign --remove-signature "$APP/Frameworks/FilzaApplySandboxExt.dylib"

cp "$REPO_ROOT/.theos/byetunes-resources/AppIconImage.png" "$APP/AppIconImage.png"
cp "$REPO_ROOT/.theos/byetunes-resources/ByeTunes-Info.plist" "$APP/ByeTunes-Info.plist"
cp "$REPO_ROOT/.theos/byetunes-resources/Config.plist" "$APP/Config.plist"
cp "$REPO_ROOT/.theos/byetunes-resources/meriyah.umd.js" "$APP/meriyah.umd.js"
cp "$REPO_ROOT/.theos/byetunes-resources/astring.umd.js" "$APP/astring.umd.js"
cp "$REPO_ROOT/.theos/byetunes-resources/yt_ejs_helper.js" "$APP/yt_ejs_helper.js"

rm -rf "$APP/Filza3105.bundle"
cp -R "$REPO_ROOT/ThirdParty/3105/Resources/Filza3105.bundle" "$APP/Filza3105.bundle"
bash "$REPO_ROOT/scripts/merge-3105-app-metadata.sh" "$APP/Info.plist"

# The WebDAV and SSH/SFTP runtimes bind to the LAN and optionally publish
# Bonjour services. Keep standalone/manual release packaging in exact parity
# with the verified universal Actions IPA so iOS can present Local Network
# permission and permit both advertised service types.
plutil -replace NSLocalNetworkUsageDescription -string \
  "Filza 27 uses your local network when you enable its WebDAV or SSH/SFTP server." \
  "$APP/Info.plist"
plutil -replace NSBonjourServices -json '["_http._tcp","_ssh._tcp"]' "$APP/Info.plist"

if [[ -n "$CATALOG" ]]; then
  cp "$CATALOG" "$APP/MCMIdentifiers.plist"
elif [[ -e "$APP/MCMIdentifiers.plist" ]]; then
  trash "$APP/MCMIdentifiers.plist"
fi

for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  [[ -s "$APP/$resource" ]] || { echo "YouTubeKit app resource missing: $resource" >&2; exit 70; }
done

NETWORK_DESCRIPTION="$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$APP/Info.plist")"
[[ "$NETWORK_DESCRIPTION" == *"WebDAV"* && "$NETWORK_DESCRIPTION" == *"SSH/SFTP"* ]] || {
  echo "local-network usage description missing WebDAV/SSH coverage" >&2
  exit 70
}
BONJOUR_JSON="$(plutil -extract NSBonjourServices json -o - "$APP/Info.plist")"
[[ "$BONJOUR_JSON" == *'"_http._tcp"'* && "$BONJOUR_JSON" == *'"_ssh._tcp"'* ]] || {
  echo "required Bonjour service declarations missing" >&2
  exit 70
}

if [[ -e "$OUTPUT_IPA" ]]; then
  trash "$OUTPUT_IPA"
fi
(
  cd "$STAGE_ROOT/stage"
  zip -qry "$OUTPUT_IPA" Payload
)

unzip -tq "$OUTPUT_IPA"
for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  unzip -l "$OUTPUT_IPA" | grep -F "$resource" >/dev/null
 done

shasum -a 256 "$OUTPUT_IPA"
