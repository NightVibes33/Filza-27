#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="097a058c984ffc33ccb697b9dfe8058be3e86244"
WORK="$ROOT/.theos/standalone-aircard-wallet-v2"
SRC="$WORK/AirCard-iOS"
OUTPUT="$ROOT/.theos/AirCard-Wallet-Standalone-unsigned.ipa"
AIRLIFT_CACHE="$ROOT/.theos/aircard-ffi-cache"

rm -rf "$WORK"
mkdir -p "$WORK" "$ROOT/.theos"

git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$SRC"
git -C "$SRC" checkout --detach "$PIN"
test "$(git -C "$SRC" rev-parse HEAD)" = "$PIN"

cp "$ROOT/FilzaAirCardLibrary.swift" "$SRC/ios-app/AirCardLibrary.swift"
cp "$ROOT/standalone-aircard/RemotePairingPortDiscovery.swift" "$SRC/ios-app/RemotePairingPortDiscovery.swift"
python3 "$ROOT/scripts/patch-standalone-aircard-wallet.py" "$SRC"

# The scanner transport is patched in rust-core. Reuse the exact patched
# AirliftFFI XCFramework when Actions restored it; otherwise build it once
# and persist it for later UI-only runs.
if [ -f "$AIRLIFT_CACHE/.complete" ] && [ -d "$AIRLIFT_CACHE/AirliftFFI.xcframework" ]; then
  echo "==> Restoring cached patched AirliftFFI.xcframework"
  rm -rf "$SRC/AirliftFFI.xcframework"
  ditto "$AIRLIFT_CACHE/AirliftFFI.xcframework" "$SRC/AirliftFFI.xcframework"
else
  echo "==> AirliftFFI cache miss; rebuilding patched Rust/XCFramework"
  chmod +x "$SRC/build-ios.sh"
  (
    cd "$SRC"
    ./build-ios.sh
  )
  rm -rf "$AIRLIFT_CACHE"
  mkdir -p "$AIRLIFT_CACHE"
  ditto "$SRC/AirliftFFI.xcframework" "$AIRLIFT_CACHE/AirliftFFI.xcframework"
  touch "$AIRLIFT_CACHE/.complete"
fi

grep -Fq 'case pairing = "Pairing"' "$SRC/ios-app/Models.swift"
grep -Fq 'case walletCards = "Wallet Cards"' "$SRC/ios-app/Models.swift"
grep -Fq 'case cardLibrary = "Library"' "$SRC/ios-app/Models.swift"
! grep -Fq 'case passcodeThemes = "Passcode"' "$SRC/ios-app/Models.swift"
! grep -Fq 'case wallpapers = "Wallpapers"' "$SRC/ios-app/Models.swift"
grep -Fq 'if showCardStudio {' "$SRC/ios-app/ContentView.swift"
grep -Fq 'AirCardLibraryView(onExit:' "$SRC/ios-app/ContentView.swift"
grep -Fq 'showCardStudio = false' "$SRC/ios-app/ContentView.swift"
grep -Fq 'vm.selectedTab = lastMainTab' "$SRC/ios-app/ContentView.swift"
grep -Fq 'Color.clear' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'fullScreenCover' "$SRC/ios-app/ContentView.swift"
grep -Fq 'Back to AirCard' "$SRC/ios-app/AirCardLibrary.swift"
! grep -Fq 'Choose Pairing File from Files…' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'PasscodeThemeTab()' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'TendiesView()' "$SRC/ios-app/ContentView.swift"
grep -Fq 'cardmaker-omega.vercel.app' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq '_remotepairing._tcp.' "$SRC/ios-app/RemotePairingPortDiscovery.swift"
grep -Fq 'al_connection_endpoint_set' "$SRC/ios-app/AppViewModel.swift"
grep -Fq 'using discovered Remote Pairing endpoint' "$SRC/rust-core/src/exploit.rs"
! grep -Fq 'Text("Credits")' "$SRC/ios-app/ContentView.swift"
grep -Fq '.ignoresSafeArea(.container, edges: .all)' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq 'contentInsetAdjustmentBehavior = .never' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq 'viewport-fit=cover' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq '.overlay(alignment: .topTrailing)' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq '.padding(.top, 6)' "$SRC/ios-app/AirCardLibrary.swift"
grep -Fq '.padding(.trailing, 64)' "$SRC/ios-app/AirCardLibrary.swift"

cd "$SRC"
xcodegen generate
chmod +x build-ipa.sh
./build-ipa.sh Release

test -s build/AirCard-iOS.ipa
cp build/AirCard-iOS.ipa "$OUTPUT"
unzip -tq "$OUTPUT"

VERIFY="$(mktemp -d)"
trap 'rm -rf "$VERIFY"' EXIT
unzip -q "$OUTPUT" -d "$VERIFY"
APP="$(find "$VERIFY/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$APP"
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/Info.plist")" = "AirCard"
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist")" = "com.nightvibes33.aircard"
plutil -p "$APP/Info.plist" | grep -Fq 'cardmaker-omega.vercel.app'
! plutil -p "$APP/Info.plist" | grep -Fq 'com.aircard.passthm'
! plutil -p "$APP/Info.plist" | grep -Fq 'com.aircard.tendies'

shasum -a 256 "$OUTPUT" | tee "$ROOT/.theos/AirCard-Wallet-Standalone-SHA256.txt"
ls -lh "$OUTPUT"
