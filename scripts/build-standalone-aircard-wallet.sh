#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="740cfd9e7f00be77887638a3e65edbdb19ff1867"
WORK="$ROOT/.theos/standalone-aircard-wallet"
SRC="$WORK/AirCard-iOS"
OUTPUT="$ROOT/.theos/AirCard-Wallet-Standalone-unsigned.ipa"

rm -rf "$WORK"
mkdir -p "$WORK" "$ROOT/.theos"

git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$SRC"
git -C "$SRC" checkout --detach "$PIN"
test "$(git -C "$SRC" rev-parse HEAD)" = "$PIN"

# Bring in only Filza 27's current Card Library surface. Do not bring in
# Filza itself, the Filza host/presentation layer, or the pairing-file UI patch.
cp "$ROOT/FilzaAirCardLibrary.swift" "$SRC/ios-app/AirCardLibrary.swift"

python3 - "$SRC" <<'PY'
from pathlib import Path
import plistlib
import sys

src = Path(sys.argv[1])

# Standalone-ize the current embedded Card Library source.
library = src / "ios-app/AirCardLibrary.swift"
s = library.read_text()
s = s.replace("FilzaAirCard", "AirCard")
s = s.replace("filzaAirCard", "airCard")
s = s.replace("inside Filza 27", "in AirCard")
s = s.replace("inside Filza", "in AirCard")
library.write_text(s)

# Exactly three visible tabs: Pairing, Wallet, Library.
models = src / "ios-app/Models.swift"
s = models.read_text()
old = '''enum AppTab: String, CaseIterable, Identifiable {
    case pairing = "Pairing"
    case walletCards = "Wallet Cards"
    case passcodeThemes = "Passcode"
    case wallpapers = "Wallpapers"
    var id: String { rawValue }
}'''
new = '''enum AppTab: String, CaseIterable, Identifiable {
    case pairing = "Pairing"
    case walletCards = "Wallet Cards"
    case cardLibrary = "Library"
    var id: String { rawValue }
}'''
assert old in s, "Pinned AirCard AppTab layout changed"
models.write_text(s.replace(old, new, 1))

content = src / "ios-app/ContentView.swift"
s = content.read_text()
old = '''            PasscodeThemeTab()
                .tabItem { Label("Passcode", systemImage: "lock.circle.fill") }
                .tag(AppTab.passcodeThemes)

            TendiesView()
                .tabItem { Label("Wallpapers", systemImage: "photo.stack.fill") }
                .tag(AppTab.wallpapers)'''
new = '''            AirCardLibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.cardLibrary)'''
assert old in s, "Pinned AirCard root tab layout changed"
s = s.replace(old, new, 1)

# This is the upstream pairing UI. Intentionally do not restore Filza's
# "Choose Pairing File from Files…" patch.
s = s.replace(
    "Apple Wallet Skins & Passcode Themes for iOS 18+",
    "Apple Wallet card skins on iOS"
)
s = s.replace(
    "Apply custom wallet card skins and passcode themes on-device using the AirTraffic sandbox escape.",
    "Apply custom Apple Wallet card skins on-device using the AirTraffic sandbox escape."
)
content.write_text(s)

# Strip document registrations belonging only to the removed Passcode/Wallpaper tabs.
info_path = src / "ios-app/Info.plist"
with info_path.open("rb") as fh:
    info = plistlib.load(fh)

info["CFBundleDisplayName"] = "AirCard"
info["NSPhotoLibraryUsageDescription"] = "AirCard needs photo access to apply custom Apple Wallet card skins."
info["WKAppBoundDomains"] = ["cardmaker-omega.vercel.app"]

blocked_types = {"com.aircard.passthm", "com.aircard.tendies"}
doc_types = []
for item in info.get("CFBundleDocumentTypes", []):
    types = set(item.get("LSItemContentTypes", []))
    if not (types & blocked_types):
        doc_types.append(item)
if doc_types:
    info["CFBundleDocumentTypes"] = doc_types
else:
    info.pop("CFBundleDocumentTypes", None)

for key in ("UTImportedTypeDeclarations", "UTExportedTypeDeclarations"):
    kept = [
        item for item in info.get(key, [])
        if item.get("UTTypeIdentifier") not in blocked_types
    ]
    if kept:
        info[key] = kept
    else:
        info.pop(key, None)

with info_path.open("wb") as fh:
    plistlib.dump(info, fh, sort_keys=False)

# Use our standalone bundle identifier while retaining upstream's executable name
# so its existing unsigned IPA packager remains valid.
project = src / "project.yml"
s = project.read_text()
s = s.replace(
    "PRODUCT_BUNDLE_IDENTIFIER: com.mak5er.aircard",
    "PRODUCT_BUNDLE_IDENTIFIER: com.nightvibes33.aircard"
)
project.write_text(s)
PY

# Contract checks before compiling.
grep -Fq 'case pairing = "Pairing"' "$SRC/ios-app/Models.swift"
grep -Fq 'case walletCards = "Wallet Cards"' "$SRC/ios-app/Models.swift"
grep -Fq 'case cardLibrary = "Library"' "$SRC/ios-app/Models.swift"
! grep -Fq 'case passcodeThemes = "Passcode"' "$SRC/ios-app/Models.swift"
! grep -Fq 'case wallpapers = "Wallpapers"' "$SRC/ios-app/Models.swift"
grep -Fq 'AirCardLibraryView()' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'PasscodeThemeTab()' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'TendiesView()' "$SRC/ios-app/ContentView.swift"
! grep -Fq 'Choose Pairing File from Files…' "$SRC/ios-app/ContentView.swift"
grep -Fq 'cardmaker-omega.vercel.app' "$SRC/ios-app/AirCardLibrary.swift"
! grep -Fq 'Filza 27' "$SRC/ios-app/AirCardLibrary.swift"

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
