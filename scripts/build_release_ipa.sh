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

# Keep the standalone release path identical to the verified Actions package.
# Metadata remains direct/public. Audio downloads are served only by the bundled
# loopback Yoink+iSH runtime; Config.plist and the developer-hosted backend stay absent.
bash "$REPO_ROOT/scripts/stage-byetunes-resources.sh" "$REPO_ROOT/.theos/byetunes-resources"
for resource in AppIconImage.png ByeTunes-Info.plist; do
  [[ -s "$REPO_ROOT/.theos/byetunes-resources/$resource" ]] || {
    echo "staged ByeTunes resource missing: $resource" >&2
    exit 70
  }
done

YOINK_BUNDLE="$REPO_ROOT/.theos/byetunes-yoink-bundle"
ISH_BUNDLE="$REPO_ROOT/.theos/byetunes-ish-bundle"
[[ -s "$YOINK_BUNDLE/server.js" ]] || {
  echo "embedded Yoink bundle missing after build" >&2
  exit 70
}
if [[ ! -s "$ISH_BUNDLE/rootfs/meta.db" ]]; then
  if command -v docker >/dev/null 2>&1; then
    bash "$REPO_ROOT/scripts/build-byetunes-ish-rootfs.sh" "$ISH_BUNDLE"
  else
    echo "ByeTunes iSH rootfs missing; build it with scripts/build-byetunes-ish-rootfs.sh (Docker required)" >&2
    exit 70
  fi
fi
grep -Eq '^ffmpeg-' "$ISH_BUNDLE/package-manifest.txt"
grep -Fq '"youtube": false' "$YOINK_BUNDLE/provenance.json"

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
rm -f "$APP/Frameworks/FilzaMondModern.dylib"
plutil -replace MinimumOSVersion -string "17.0" "$APP/Info.plist"

# Upstream FilzaSlop strips Filza/SDK URL handlers from release IPAs so other
# apps cannot fingerprint this build through canOpenURL:. Keep the downstream
# runtime integrations intact and remove only the packaged URL declarations.
plutil -remove CFBundleURLTypes "$APP/Info.plist" 2>/dev/null || true
if plutil -extract CFBundleURLTypes json -o - "$APP/Info.plist" >/dev/null 2>&1; then
  echo "CFBundleURLTypes was not stripped from packaged Info.plist" >&2
  exit 70
fi

cp "$REPO_ROOT/.theos/byetunes-resources/AppIconImage.png" "$APP/AppIconImage.png"
cp "$REPO_ROOT/.theos/byetunes-resources/ByeTunes-Info.plist" "$APP/ByeTunes-Info.plist"
rm -f "$APP/Config.plist"

rm -rf "$APP/ByeTunesYoink.bundle" "$APP/ByeTunesISH.bundle"
mkdir -p "$APP/ByeTunesYoink.bundle" "$APP/ByeTunesISH.bundle"
cp -R "$YOINK_BUNDLE/." "$APP/ByeTunesYoink.bundle/"
cp -R "$ISH_BUNDLE/." "$APP/ByeTunesISH.bundle/"

if otool -L "$APP/Frameworks/FilzaApplySandboxExt.dylib" | grep -Fq 'NodeMobile.framework/NodeMobile'; then
  rm -rf "$APP/Frameworks/NodeMobile.framework"
  cp -R "$REPO_ROOT/Vendor/NodeMobile/NodeMobile.framework" "$APP/Frameworks/NodeMobile.framework"
  codesign --remove-signature "$APP/Frameworks/NodeMobile.framework/NodeMobile" >/dev/null 2>&1 || true
fi

rm -rf "$APP/Filza3105.bundle"
cp -R "$REPO_ROOT/ThirdParty/3105/Resources/Filza3105.bundle" "$APP/Filza3105.bundle"
bash "$REPO_ROOT/scripts/merge-3105-app-metadata.sh" "$APP/Info.plist"

# The WebDAV and SSH/SFTP runtimes bind to the LAN and optionally publish
# Bonjour services. Keep standalone/manual release packaging in exact parity
# with the verified modern Actions IPA so iOS can present Local Network
# permission and permit both advertised service types.
plutil -replace NSLocalNetworkUsageDescription -string \
  "Filza 27 uses your local network for WebDAV, SSH/SFTP, and on-device Remote Pairing through LocalDevVPN." \
  "$APP/Info.plist"
plutil -replace NSBonjourServices -json '["_http._tcp","_ssh._tcp","_remotepairing._tcp"]' "$APP/Info.plist"
plutil -replace NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$APP/Info.plist"

if [[ -n "$CATALOG" ]]; then
  cp "$CATALOG" "$APP/MCMIdentifiers.plist"
elif [[ -e "$APP/MCMIdentifiers.plist" ]]; then
  trash "$APP/MCMIdentifiers.plist"
fi

[[ "$(plutil -extract MinimumOSVersion raw -o - "$APP/Info.plist")" == "17.0" ]] || { echo "unexpected MinimumOSVersion" >&2; exit 70; }
[[ ! -e "$APP/Frameworks/FilzaMondModern.dylib" ]] || { echo "stale split Mond runtime present" >&2; exit 70; }

# Enforce direct/public metadata plus loopback-only local downloads.
[[ ! -e "$APP/Config.plist" ]] || {
  echo "forbidden ByeTunes Config.plist present in packaged app" >&2
  exit 70
}
BYETUNES_BINARY="$APP/Frameworks/FilzaApplySandboxExt.dylib"
[[ -s "$BYETUNES_BINARY" ]] || {
  echo "packaged FilzaApplySandboxExt.dylib missing" >&2
  exit 70
}
for required in 'syllable-lyrics' 'media-user-token' 'Apple Music Synced' 'http://127.0.0.1:41337/api/download' 'LocalDevVPN Remote Pairing connected via'; do
  if ! LC_ALL=C grep -aFq "$required" "$BYETUNES_BINARY"; then
    echo "required ByeTunes runtime marker missing from packaged binary: $required" >&2
    exit 70
  fi
done
for forbidden in 'api.byetunes.xyz' 'ByeTunesApiUrl'; do
  if LC_ALL=C grep -aFq "$forbidden" "$BYETUNES_BINARY"; then
    echo "forbidden developer-hosted ByeTunes backend marker in packaged binary: $forbidden" >&2
    exit 70
  fi
done
[[ -s "$APP/ByeTunesYoink.bundle/server.js" ]] || { echo "packaged Yoink runtime missing" >&2; exit 70; }
[[ -s "$APP/ByeTunesISH.bundle/rootfs/meta.db" ]] || { echo "packaged iSH rootfs missing" >&2; exit 70; }
grep -Eq '^ffmpeg-' "$APP/ByeTunesISH.bundle/package-manifest.txt"
grep -Fq '"youtube": false' "$APP/ByeTunesYoink.bundle/provenance.json"
[[ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw -o - "$APP/Info.plist")" == "true" ]] || {
  echo "ATS local networking is not enabled" >&2
  exit 70
}

NETWORK_DESCRIPTION="$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$APP/Info.plist")"
[[ "$NETWORK_DESCRIPTION" == *"WebDAV"* && "$NETWORK_DESCRIPTION" == *"SSH/SFTP"* ]] || {
  echo "local-network usage description missing WebDAV/SSH coverage" >&2
  exit 70
}
BONJOUR_JSON="$(plutil -extract NSBonjourServices json -o - "$APP/Info.plist")"
[[ "$BONJOUR_JSON" == *'"_http._tcp"'* && "$BONJOUR_JSON" == *'"_ssh._tcp"'* && "$BONJOUR_JSON" == *'"_remotepairing._tcp"'* ]] || {
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
shasum -a 256 "$OUTPUT_IPA"
