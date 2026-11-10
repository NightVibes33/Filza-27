#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/NFCARD"
PATCH_WORK="$ROOT/.theos/nfcard-patch-source"
NFCARD_PIN="16f8bfd20a88a474f59c2d6eda291164a1cc015f"
AIRCARD_PIN="097a058c984ffc33ccb697b9dfe8058be3e86244"
EROSION_PIN="a8dc7e48b13e130e69c28269a43fc4a8b456952a"
EROSION_WORK="$ROOT/.theos/erozzion-source"

# CI restores only the staged iOS sources + final AirliftFFI archive, not Cargo's
# huge target directory. If those immutable pinned outputs are present and
# self-consistent, do not reclone/repatch/rebuild them on every app build.
if [[ -f "$DEST/NFCARD_PINNED_REVISION" &&
      -f "$DEST/AIRCARD_PINNED_REVISION" &&
      "$(cat "$DEST/NFCARD_PINNED_REVISION" 2>/dev/null)" == "$NFCARD_PIN" &&
      "$(cat "$DEST/AIRCARD_PINNED_REVISION" 2>/dev/null)" == "$AIRCARD_PIN" &&
      -f "$DEST/EROSION_PINNED_REVISION" &&
      "$(cat "$DEST/EROSION_PINNED_REVISION" 2>/dev/null)" == "$EROSION_PIN" &&
      -s "$DEST/ios-app/NFCARDContentView.swift" &&
      -s "$DEST/ios-app/AppViewModel.swift" &&
      -s "$DEST/ios-app/PairingController.swift" &&
      -s "$DEST/ios-app/AirCardLibrary.swift" &&
      -s "$DEST/ios-app/RemotePairingPortDiscovery.swift" &&
      -s "$DEST/rust-core/src/exploit.rs" &&
      "$(grep -c 'FILZA_AIRLIFT_APP_BUNDLE_SAFE_ROUTE' "$DEST/rust-core/src/exploit.rs" || true)" -ge 1 &&
      -s "$DEST/AirliftFFI/lib/libairlift_ffi.a" &&
      -s "$DEST/AirliftFFI/include/AirliftFFI/airlift.h" &&
      "$(grep -c 'al_exploit_inject_folder' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h" || true)" -ge 1 &&
      "$(grep -c 'al_find_app_container' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h" || true)" -ge 1 &&
      -s "$DEST/AirliftFFI/include/AirliftFFI/module.modulemap" ]]; then
  grep -Fq 'struct NFCARDContentView: View' "$DEST/ios-app/NFCARDContentView.swift"
  grep -Fq 'al_pairing_run_host' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_connection_endpoint_set' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_list_app_containers' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_exploit_read_folder' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_exploit_inject_folder' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_find_app_container' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  grep -Fq 'al_syslog_stream_start' "$DEST/AirliftFFI/include/AirliftFFI/airlift.h"
  echo "Reused cached staged NFCARD $NFCARD_PIN on AirCard upstream $AIRCARD_PIN"
  exit 0
fi

rm -rf "$DEST" "$PATCH_WORK" "$EROSION_WORK"
mkdir -p "$ROOT/.theos"

git clone --filter=blob:none https://github.com/Mak5er/AirCard-iOS.git "$DEST"
git -C "$DEST" checkout --detach "$AIRCARD_PIN"
test "$(git -C "$DEST" rev-parse HEAD)" = "$AIRCARD_PIN"

# Retain NFCARD's existing UI and pairing, but use Erosion's additive
# InstallationProxy, app-group, remote snapshot, and file-write Rust API.
# Compile a single AirliftFFI library to prevent duplicate exported symbols.
git clone --filter=blob:none https://github.com/ceoca69/erozzion-mod.git "$EROSION_WORK"
git -C "$EROSION_WORK" checkout --detach "$EROSION_PIN"
test "$(git -C "$EROSION_WORK" rev-parse HEAD)" = "$EROSION_PIN"
EROSION_CORE="$EROSION_WORK/AirCard-iOS-main/rust-core"
test -s "$EROSION_CORE/src/exploit.rs"
test -s "$EROSION_CORE/src/lib.rs"
test -s "$EROSION_CORE/include/airlift.h"
cp -R "$EROSION_CORE/." "$DEST/rust-core/"

git clone --filter=blob:none https://github.com/NightVibes33/NFCARD.git "$PATCH_WORK"
git -C "$PATCH_WORK" checkout --detach "$NFCARD_PIN"
test "$(git -C "$PATCH_WORK" rev-parse HEAD)" = "$NFCARD_PIN"

cp "$PATCH_WORK/Sources/AirCardLibrary.swift" "$DEST/ios-app/AirCardLibrary.swift"
cp "$PATCH_WORK/Sources/RemotePairingPortDiscovery.swift" "$DEST/ios-app/RemotePairingPortDiscovery.swift"
cp "$PATCH_WORK/Sources/NFCARDNativeShell.swift" "$DEST/ios-app/NFCARDNativeShell.swift"
python3 "$PATCH_WORK/scripts/patch-upstream.py" "$DEST"
# Preserve Erosion's restoration-aware reader for installed .app bundles.
# Cached libraries without this exact patch marker must be rebuilt.
python3 "$ROOT/scripts/patch-erosion-app-bundle-safe-read.py" "$DEST/rust-core/src/exploit.rs"
grep -Fq 'FILZA_AIRLIFT_APP_BUNDLE_SAFE_ROUTE' "$DEST/rust-core/src/exploit.rs"

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
printf '%s\n' "$EROSION_PIN" > "$DEST/EROSION_PINNED_REVISION"

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
grep -Fq 'al_list_app_containers' "$DEST/rust-core/include/airlift.h"
grep -Fq 'al_exploit_read_folder' "$DEST/rust-core/include/airlift.h"
grep -Fq 'al_exploit_write_file' "$DEST/rust-core/include/airlift.h"
grep -Fq 'al_exploit_inject_folder' "$DEST/rust-core/include/airlift.h"
grep -Fq 'al_find_app_container' "$DEST/rust-core/include/airlift.h"
grep -Fq 'cardmaker-omega.vercel.app' "$DEST/ios-app/AirCardLibrary.swift"
grep -Fq '_remotepairing._tcp.' "$DEST/ios-app/RemotePairingPortDiscovery.swift"

echo "Staged NFCARD $NFCARD_PIN on AirCard $AIRCARD_PIN with Erosion $EROSION_PIN"
