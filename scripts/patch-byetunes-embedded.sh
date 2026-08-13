#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
CONTENT="ByeTunes/MusicManager/ContentView.swift"
test -f "$DEVICE"
test -f "$CONTENT"

python3 - "$DEVICE" "$CONTENT" <<'PY'
from pathlib import Path
import re
import sys

device = Path(sys.argv[1])
content = Path(sys.argv[2])

ds = device.read_text()

# Filza does not own ByeTunes' application-group entitlement. Keep the embedded
# pairing copy in Filza's persistent Documents container so it survives process
# relaunches and can be reused without reopening the document picker.
pairing_property_start = ds.find("    var regularPairingFile: URL {")
pairing_property_end = ds.find("\n    var rpPairingFile: URL {", pairing_property_start)
if pairing_property_start < 0 or pairing_property_end < 0:
    raise SystemExit('DeviceManager regularPairingFile property not found')
persistent_pairing_property = '''    var regularPairingFile: URL {
        URL.documentsDirectory
            .appendingPathComponent("pairing file", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }
'''
ds = ds[:pairing_property_start] + persistent_pairing_property + ds[pairing_property_end:]

init_start = ds.find("    private init() {")
if init_start < 0:
    raise SystemExit('DeviceManager private init not found')
init_end = ds.find("\n    private func ", init_start)
if init_end < 0:
    raise SystemExit('DeviceManager private init end not found')

# Filza owns the process. DeviceManager.shared is created while SwiftUI builds
# ContentView, so its embedded initializer must not touch process-global FFI,
# process-global FFI, sockets, or tunnel state. Restoring the saved pairing
# file's local state is intentionally safe and required across app launches.
safe_init = '''    private init() {
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] BUILD VERSION: \\(BUILD_VERSION)")
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] Filza embed: inert startup initialized")
        hasValidExpectedPairingFile = false
        heartbeatReady = false
        connectionStatus = "Disconnected"
        let folderPath = regularPairingFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folderPath,
                withIntermediateDirectories: true
            )
        } catch {
            Logger.shared.log("[DeviceManager] Filza embed: pairing directory error: \\(error.localizedDescription)")
        }
        refreshExpectedPairingFileState()
        Logger.shared.log("[DeviceManager] Filza embed: persistent pairing state restored=\\(hasValidExpectedPairingFile) path=\\(expectedPairingFile.path)")
        Logger.shared.log("[DeviceManager] Filza embed: transport work deferred until ContentView appears or an explicit import completes")
    }
'''
ds = ds[:init_start] + safe_init + ds[init_end:]

# Read the security-scoped selection before replacing the saved copy. Atomic
# data writes also handle selecting the already-saved file and avoid leaving a
# missing/partial pairing file if the process is interrupted during import.
old_import_write = '''        if FileManager.default.fileExists(atPath: expectedPairingFile.path) {
            try FileManager.default.removeItem(at: expectedPairingFile)
        }
        try FileManager.default.copyItem(at: url, to: expectedPairingFile)

        refreshExpectedPairingFileState()
'''
new_import_write = '''        let importedPairingData = try Data(contentsOf: url)
        try importedPairingData.write(to: expectedPairingFile, options: .atomic)
        Logger.shared.log("[DeviceManager] Filza embed: imported pairing file persisted at \\(expectedPairingFile.path)")

        refreshExpectedPairingFileState()
'''
if old_import_write not in ds:
    raise SystemExit('DeviceManager pairing import write anchor not found')
ds = ds.replace(old_import_write, new_import_write, 1)
device.write_text(ds)

cs = content.read_text()
cs = re.sub(r'^[ \t]+$', '', cs, flags=re.MULTILINE)
cs = cs.replace('    @State private var showSplash = true\n', '')
cs = cs.replace('''            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if !showSplash {
                Group {
''', '''            Group {
''')
cs = cs.replace('''                }
            }

            if !showSplash && manager.needsRPPairingFileUpgrade {
''', '''            }

            if manager.needsRPPairingFileUpgrade {
''')
cs = cs.replace('''            if !showSplash,
               let availableUpdate,
''', '''            if let availableUpdate,
''')
new_appear = '''        .onAppear {
            // Filza embed: rendering this view must be side-effect free. In the
            // standalone app these startup helpers touch app-group storage,
            // pairing parsers, network transport and update state. None of that
            // is required to draw the UI, and a failure in any one subsystem
            // previously took down Filza with it.
            Logger.shared.log("[ContentView] Filza embed: immediate safe onAppear entered")
            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile
            if manager.hasValidExpectedPairingFile {
                Logger.shared.log("[ContentView] Filza embed: restored persisted pairing file; reconnecting automatically")
                manager.startHeartbeat()
            } else {
                Logger.shared.log("[ContentView] Filza embed: no persisted pairing file; showing import flow")
            }
        }
'''
appear_start = cs.find('        .onAppear {')
appear_end = cs.find('        .onOpenURL', appear_start)
if appear_start < 0 or appear_end < 0:
    raise SystemExit('embedded ContentView onAppear anchor not found')
cs = cs[:appear_start] + new_appear + cs[appear_end:]
if 'showSplash' in cs or 'SplashView()' in cs:
    raise SystemExit('embedded splash route was not fully removed')
content.write_text(cs)

visible_replacements = {
    Path("ByeTunes/MusicManager/OnboardingView.swift"): [
        ('Text("ByeTunes")', 'Text("Music Library")'),
    ],
    Path("ByeTunes/MusicManager/ContentView.swift"): [
        ('before ByeTunes can connect', 'before Music Library can connect'),
        ('Text("ByeTunes \\(update.version) is available.', 'Text("Music Library \\(update.version) is available.'),
    ],
    Path("ByeTunes/MusicManager/SettingsView.swift"): [
        ('Text("Add ByeTunes Shortcut")', 'Text("Add Music Library Shortcut")'),
        ('title: "ByeTunes \\(update.version) is available"', 'title: "Music Library \\(update.version) is available"'),
        ('title: "ByeTunes is up to date"', 'title: "Music Library is up to date"'),
    ],
}
for path, replacements in visible_replacements.items():
    text = path.read_text()
    for old, new in replacements:
        if old not in text and new not in text:
            raise SystemExit(f'visible branding anchor not found in {path}: {old}')
        text = text.replace(old, new)
    path.write_text(text)
PY

grep -Fq 'Filza embed: inert startup initialized' "$DEVICE"
grep -Fq 'URL.documentsDirectory' "$DEVICE"
grep -Fq 'persistent pairing state restored=' "$DEVICE"
grep -Fq 'imported pairing file persisted at' "$DEVICE"
grep -Fq 'Filza embed: immediate safe onAppear entered' "$CONTENT"
grep -Fq 'restored persisted pairing file; reconnecting automatically' "$CONTENT"
! grep -Fq 'SplashView()' "$CONTENT"
! grep -Fq 'showSplash' "$CONTENT"
grep -Fq 'Text("Music Library")' ByeTunes/MusicManager/OnboardingView.swift
! grep -Fq 'Text("ByeTunes")' ByeTunes/MusicManager/OnboardingView.swift
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'idevice_init_logger('
# The explicit import/connect paths must remain present; this patch only removes
# automatic startup work.
grep -Fq 'func importPairingFile(from url: URL) throws' "$DEVICE"
grep -Fq 'func startHeartbeat(forceReconnect: Bool = false' "$DEVICE"
