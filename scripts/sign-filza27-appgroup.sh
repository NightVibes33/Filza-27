#!/usr/bin/env bash
# Sign actual Filza 27 binary using the Apple Developer provisioned App Group.
# The unsigned IPA alone cannot confer this capability.
set -Eeuo pipefail
if [ "$#" -ne 2 ]; then
  echo "Usage: sign-filza27-appgroup.sh unsigned.ipa signed.ipa" >&2
  exit 2
fi
IN_IPA="$1"; OUT_IPA="$2"
: "$FILZA_SIGNING_P12_BASE64"
: "$FILZA_SIGNING_P12_PASSWORD"
: "$FILZA_APPGROUP_PROFILE_BASE64"
: "$FILZA_SIGNING_IDENTITY"
test -s "$IN_IPA"
command -v security >/dev/null
command -v codesign >/dev/null
command -v python3 >/dev/null

TMP="$(mktemp -d /tmp/filza27-sign.XXXXXXXX)"
KEYCHAIN="$TMP/filza27.keychain-db"
KEYPASS="$(uuidgen)-$(uuidgen)"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

printf '%s' "$FILZA_SIGNING_P12_BASE64" | base64 -D > "$TMP/id.p12"
printf '%s' "$FILZA_APPGROUP_PROFILE_BASE64" | base64 -D > "$TMP/app.mobileprovision"
security cms -D -i "$TMP/app.mobileprovision" > "$TMP/profile.plist"
python3 scripts/filza27-appgroup-entitlements.py \
  --prepare "$TMP/profile.plist" "$TMP/entitlements.plist"

security create-keychain -p "$KEYPASS" "$KEYCHAIN"
security unlock-keychain -p "$KEYPASS" "$KEYCHAIN"
security set-keychain-settings -lut 18000 "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" \
  -P "$FILZA_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYPASS" "$KEYCHAIN" >/dev/null
SIGNING_LINE="$(security find-identity -v -p codesigning "$KEYCHAIN" |
  grep -F "$FILZA_SIGNING_IDENTITY" | head -n 1)" || {
  echo "The requested signing identity is not in the imported P12." >&2
  exit 1
}
CERT_SHA="$(printf '%s\n' "$SIGNING_LINE" | grep -Eo '[[:xdigit:]]{40}' | head -n 1)"
python3 scripts/filza27-appgroup-entitlements.py \
  --check-certificate "$TMP/profile.plist" "$CERT_SHA"

unzip -tq "$IN_IPA"
mkdir -p "$TMP/stage"
unzip -q "$IN_IPA" -d "$TMP/stage"
APP=""
COUNT=0
for item in "$TMP"/stage/Payload/*.app; do
  test -d "$item" || continue
  APP="$item"; COUNT=$((COUNT + 1))
done
if [ "$COUNT" -ne 1 ]; then
  echo "Expected one Filza 27 app in the unsigned IPA." >&2
  exit 1
fi
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
if [ "$APP_ID" != "com.filza27.nigtvibes33" ]; then
  echo "Filza app ID and provisioned App Group profile do not match." >&2
  exit 1
fi
cp "$TMP/app.mobileprovision" "$APP/embedded.mobileprovision"

# Sign embedded code separately before the app bundle; no injected shortcuts.
if [ -d "$APP/Frameworks" ]; then
  while IFS= read -r -d '' item; do
    codesign --force --sign "$FILZA_SIGNING_IDENTITY" --keychain "$KEYCHAIN" \
      --timestamp=none "$item"
  done < <(find "$APP/Frameworks" -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' item; do
    codesign --force --sign "$FILZA_SIGNING_IDENTITY" --keychain "$KEYCHAIN" \
      --timestamp=none "$item"
  done < <(find "$APP/Frameworks" -type d -name '*.framework' -print0)
fi
if [ -d "$APP/PlugIns" ] && find "$APP/PlugIns" -name '*.appex' -print -quit | grep -q .; then
  echo "This app has extensions needing their own profiles; refusing incorrect signing." >&2
  exit 1
fi

codesign --force --sign "$FILZA_SIGNING_IDENTITY" --keychain "$KEYCHAIN" \
  --timestamp=none --generate-entitlement-der \
  --entitlements "$TMP/entitlements.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

codesign -d --entitlements :- "$APP" > "$TMP/signed.plist" 2> "$TMP/codesign.log"
python3 scripts/filza27-appgroup-entitlements.py --verify-signed "$TMP/signed.plist"

mkdir -p "$(dirname "$OUT_IPA")"
rm -f "$OUT_IPA"
(cd "$TMP/stage" && zip -qry "$OUT_IPA" Payload)
test -s "$OUT_IPA"
unzip -tq "$OUT_IPA"
shasum -a 256 "$OUT_IPA"
echo "Apple profile and final Filza 27 signature both authorize group.com.filza27.nigtvibes33.worsequery."
