#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/NFCARD"
PATCH_WORK="$ROOT/.theos/nfcard-patch-source"
NFCARD_PIN="4dbacf6b503d861dba605286f9ee6f7904c8a81f"
AIRCARD_PIN="097a058c984ffc33ccb697b9dfe8058be3e86244"

rm -rf "$DEST" "$PATCH_WORK"
mkdir -p "$ROOT/.theos"

git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$DEST"
git -C "$DEST" checkout --detach "$AIRCARD_PIN"
test "$(git -C "$DEST" rev-parse HEAD)" = "$AIRCARD_PIN"

git clone --filter=blob:none https://github.com/NightVibes33/NFCARD.git "$PATCH_WORK"
git -C "$PATCH_WORK" checkout --detach "$NFCARD_PIN"
test "$(git -C "$PATCH_WORK" rev-parse HEAD)" = "$NFCARD_PIN"

cp "$PATCH_WORK/Sources/AirCardLibrary.swift" "$DEST/ios-app/AirCardLibrary.swift"
cp "$PATCH_WORK/Sources/RemotePairingPortDiscovery.swift" "$DEST/ios-app/RemotePairingPortDiscovery.swift"
cp "$PATCH_WORK/Sources/NFCARDNativeShell.swift" "$DEST/ios-app/NFCARDNativeShell.swift"
python3 "$PATCH_WORK/scripts/patch-upstream.py" "$DEST"

rm -f "$DEST/ios-app/AirCardApp.swift"

# Filza already compiles ByeTunes ContentView into the same Swift module.
# Keep NFCARD's source intact except for the root type/file name collision.
mv "$DEST/ios-app/ContentView.swift" "$DEST/ios-app/NFCARDContentView.swift"
python3 - "$DEST/ios-app/NFCARDContentView.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
count = s.count("struct ContentView: View")
if count != 1:
    raise SystemExit(f"expected one NFCARD ContentView root, found {count}")
p.write_text(s.replace("struct ContentView: View", "struct NFCARDContentView: View", 1))
PY

printf '%s\n' "$NFCARD_PIN" > "$DEST/NFCARD_PINNED_REVISION"
printf '%s\n' "$AIRCARD_PIN" > "$DEST/AIRCARD_PINNED_REVISION"

grep -Fq 'struct NFCARDContentView: View' "$DEST/ios-app/NFCARDContentView.swift"
grep -Fq 'case pairing = "Pairing"' "$DEST/ios-app/Models.swift"
grep -Fq 'case walletCards = "Wallet Cards"' "$DEST/ios-app/Models.swift"
grep -Fq 'case cardLibrary = "Library"' "$DEST/ios-app/Models.swift"
! grep -Fq 'case passcodeThemes = "Passcode"' "$DEST/ios-app/Models.swift"
! grep -Fq 'case wallpapers = "Wallpapers"' "$DEST/ios-app/Models.swift"
grep -Fq 'NFCARDPairingTab()' "$DEST/ios-app/NFCARDContentView.swift"
grep -Fq 'NFCARDWalletCardsTab()' "$DEST/ios-app/NFCARDContentView.swift"
grep -Fq 'Pair with NFCARD' "$DEST/ios-app/PairingController.swift"
grep -Fq 'al_connection_endpoint_set' "$DEST/ios-app/AppViewModel.swift"
grep -Fq 'cardmaker-omega.vercel.app' "$DEST/ios-app/AirCardLibrary.swift"
grep -Fq '_remotepairing._tcp.' "$DEST/ios-app/RemotePairingPortDiscovery.swift"

echo "Staged NFCARD $NFCARD_PIN on AirCard upstream $AIRCARD_PIN"
