#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
test -f "$DEVICE"

python3 - "$DEVICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
log = '        Logger.shared.log("[DeviceManager] Filza embed: imported pairing file persisted at \\(expectedPairingFile.path)")\n'

# ByeTunes 2.4 persisted the imported file with copyItem directly. 2.5 first
# validates through a temporary file, then atomically replace/moves it and
# applies 0600 permissions. Keep that upstream 2.5 behavior intact and place
# Filza's existing persistence instrumentation after the completed write.
if log not in text:
    anchor = '        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expectedPairingFile.path)\n\n        refreshExpectedPairingFileState()\n'
    replacement = '        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expectedPairingFile.path)\n' + log + '\n        refreshExpectedPairingFileState()\n'
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(f"ByeTunes 2.5 pairing persistence anchor: expected 1, found {count}")
    text = text.replace(anchor, replacement, 1)
    path.write_text(text)

if log not in path.read_text():
    raise SystemExit("ByeTunes 2.5 pairing instrumentation was not installed")
print("Adapted existing Filza pairing-import instrumentation to ByeTunes 2.5 atomic import path")
PY
