#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
CONTENT="ByeTunes/MusicManager/ContentView.swift"
test -f "$DEVICE"
test -f "$CONTENT"

python3 - "$DEVICE" "$CONTENT" <<'PY'
from pathlib import Path
import sys

device = Path(sys.argv[1])
content = Path(sys.argv[2])

ds = device.read_text()
old_logger = '''        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("idevice-logs.txt").path
        let cString = strdup(logPath)
        defer { free(cString) }
        idevice_init_logger(Info, Disabled, cString)
'''
new_logger = '''        // Filza owns this process. Do not initialize idevice's process-global
        // tracing/FFI logger while SwiftUI is still constructing the embedded root.
        // Transport initialization remains available from the explicit pairing/import flow.
        Logger.shared.log("[DeviceManager] Filza embed: deferred idevice logger initialization")
'''
if old_logger in ds:
    ds = ds.replace(old_logger, new_logger, 1)
elif new_logger not in ds:
    raise SystemExit('embedded DeviceManager logger patch anchor not found')
device.write_text(ds)

cs = content.read_text()
old_startup = '''            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile || manager.needsRPPairingFileUpgrade
            if manager.hasValidExpectedPairingFile {
                manager.startHeartbeat()
            }
'''
new_startup = '''            // Filza embed: mount the full ByeTunes UI before touching idevice/RP FFI.
            // The existing onboarding/import action remains the explicit transport entry point.
            hasCompletedOnboarding = false
            Logger.shared.log("[ContentView] Filza embed: transport startup deferred until explicit pairing import")
'''
if old_startup in cs:
    cs = cs.replace(old_startup, new_startup, 1)
elif new_startup not in cs:
    raise SystemExit('embedded ContentView startup patch anchor not found')
content.write_text(cs)
PY

grep -Fq 'Filza embed: deferred idevice logger initialization' "$DEVICE"
grep -Fq 'Filza embed: transport startup deferred until explicit pairing import' "$CONTENT"
! grep -A12 -F 'private init() {' "$DEVICE" | grep -Fq 'idevice_init_logger('
