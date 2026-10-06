#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEVICE="$ROOT/iDeviceManager.swift"

test -s "$DEVICE" || { echo "missing ByeTunes iDeviceManager.swift" >&2; exit 1; }

python3 - "$DEVICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Preserve the real ByeTunes transport and discovery implementation verbatim.
# Only pause its reconnect watcher while Filza's pairing sheet owns the session.
# Pairing host and heartbeat transport must never compete for the old pairing
# session. ByeTunesOnDevicePairing suspends reconnect before advertising and
# resumes after the fresh RP pairing file has been persisted.
if "private var autoReconnectSuspended = false" not in text:
    anchor = "    private var autoReconnectTimer: DispatchSourceTimer?\n"
    if anchor not in text:
        raise SystemExit("autoReconnectTimer anchor missing")
    text = text.replace(
        anchor,
        anchor + "    private var autoReconnectSuspended = false\n",
        1,
    )

if "func setAutoReconnectSuspended(_ suspended: Bool)" not in text:
    anchor = "    private func installAutoReconnectWatcher() {"
    pos = text.find(anchor)
    if pos < 0:
        raise SystemExit("auto reconnect watcher missing")
    method = '''    func setAutoReconnectSuspended(_ suspended: Bool) {
        autoReconnectSuspended = suspended
        if suspended {
            Logger.shared.log("[DeviceManager] Auto-reconnect suspended for on-device pairing")
            stopHeartbeat()
        } else {
            lastHeartbeatAttemptStartedAt = .distantPast
            Logger.shared.log("[DeviceManager] Auto-reconnect resumed after on-device pairing")
        }
    }

'''
    text = text[:pos] + method + text[pos:]

if 'if self.autoReconnectSuspended {' not in text:
    anchor = "            guard UIApplication.shared.applicationState == .active else { return }\n"
    if text.count(anchor) != 1:
        raise SystemExit("upstream reconnect watcher anchor missing or ambiguous")
    text = text.replace(anchor, anchor + "\n            if self.autoReconnectSuspended { return }\n", 1)

path.write_text(text)
PY

grep -Fq 'RemotePairingDiscovery.resolvePort() ?? RP_PAIRING_PORT' "$DEVICE"
grep -Fq 'var addr = makeSocketAddress(port: resolvedPort)' "$DEVICE"
grep -Fq 'private let DEVICE_HOST = "10.7.0.1"' "$DEVICE"
grep -Fq 'func setAutoReconnectSuspended(_ suspended: Bool)' "$DEVICE"
! grep -Fq 'ByeTunesTCPProbe' "$DEVICE"
! grep -Fq 'filzaByeTunesLastRPPairingHost' "$DEVICE"

echo "Preserved upstream ByeTunes LocalDevVPN transport; added pairing-sheet reconnect suspension"
