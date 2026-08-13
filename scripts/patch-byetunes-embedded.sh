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
init_start = ds.find("    private init() {")
if init_start < 0:
    raise SystemExit('DeviceManager private init not found')
init_end = ds.find("\n    private func ", init_start)
if init_end < 0:
    raise SystemExit('DeviceManager private init end not found')

# Filza owns the process. DeviceManager.shared is created while SwiftUI builds
# ContentView, so its embedded initializer must not touch process-global FFI,
# app-group storage, pairing files, sockets, or tunnel state. Those operations
# stay in the existing explicit import/connect methods and begin only after the
# user presses the pairing-file import action.
safe_init = '''    private init() {
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] BUILD VERSION: \\(BUILD_VERSION)")
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] Filza embed: inert startup initialized")
        hasValidExpectedPairingFile = false
        heartbeatReady = false
        connectionStatus = "Disconnected"
        Logger.shared.log("[DeviceManager] Filza embed: all pairing/transport/storage work deferred until explicit import")
    }
'''
ds = ds[:init_start] + safe_init + ds[init_end:]
device.write_text(ds)

cs = content.read_text()
old_appear = '''        .onAppear {
            cleanupLegacyImportedAudioFiles()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile || manager.needsRPPairingFileUpgrade
            if manager.hasValidExpectedPairingFile {
                manager.startHeartbeat()
            }
            
            
            checkPendingInjections()
            checkForAppUpdate()
        }
'''
new_appear = '''        .onAppear {
            // Filza embed: rendering this view must be side-effect free. In the
            // standalone app these startup helpers touch app-group storage,
            // pairing parsers, network transport and update state. None of that
            // is required to draw the UI, and a failure in any one subsystem
            // previously took down Filza with it.
            Logger.shared.log("[ContentView] Filza embed: safe onAppear entered")
            hasCompletedOnboarding = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
                Logger.shared.log("[ContentView] Filza embed: splash completed; waiting for explicit pairing import")
            }
        }
'''
if old_appear not in cs:
    raise SystemExit('embedded ContentView onAppear anchor not found')
cs = cs.replace(old_appear, new_appear, 1)
content.write_text(cs)
PY

grep -Fq 'Filza embed: inert startup initialized' "$DEVICE"
grep -Fq 'all pairing/transport/storage work deferred until explicit import' "$DEVICE"
grep -Fq 'Filza embed: safe onAppear entered' "$CONTENT"
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'idevice_init_logger('
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'regularPairingFile'
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'refreshExpectedPairingFileState()'
# The explicit import/connect paths must remain present; this patch only removes
# automatic startup work.
grep -Fq 'func importPairingFile(from url: URL) throws' "$DEVICE"
grep -Fq 'func startHeartbeat(forceReconnect: Bool = false' "$DEVICE"
