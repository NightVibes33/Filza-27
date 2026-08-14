#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
CONTENT="ByeTunes/MusicManager/ContentView.swift"
SONG_METADATA="ByeTunes/MusicManager/SongMetadata.swift"
test -f "$DEVICE"
test -f "$CONTENT"
test -f "$SONG_METADATA"

python3 - "$DEVICE" "$CONTENT" "$SONG_METADATA" <<'PY'
from pathlib import Path
import re
import sys

device = Path(sys.argv[1])
content = Path(sys.argv[2])
song_metadata = Path(sys.argv[3])

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
if old_import_write in ds:
    ds = ds.replace(old_import_write, new_import_write, 1)
elif 'Filza embed: imported pairing file persisted at' not in ds:
    raise SystemExit('DeviceManager pairing import write anchor not found')
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

# Apple changed the ordering of fields in the web-player JWT header. The
# standalone ByeTunes matcher required the token to begin with {"alg":...},
# which now rejects the valid current {"typ":...,"alg":...} token and leaves
# the Download tab with no search results. Match complete JWTs, decode their
# payloads, reject expired candidates and prefer Apple's AMPWebPlay token.
sms = song_metadata.read_text()
new_token_block = '''            let tokenPattern = #"eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{20,}"#
            guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else {
                await Logger.shared.log("[AppleMusicAPI] ⚠️ Failed to construct JWT matcher")
                return nil
            }

            let tokenMatches = tokenRegex.matches(
                in: jsContent,
                range: NSRange(jsContent.startIndex..<jsContent.endIndex, in: jsContent)
            )

            func payload(for token: String) -> [String: Any]? {
                let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
                guard pieces.count == 3 else { return nil }
                var encoded = String(pieces[1])
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                let padding = (4 - encoded.count % 4) % 4
                encoded += String(repeating: "=", count: padding)
                guard let data = Data(base64Encoded: encoded),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? [String: Any] else { return nil }
                return dictionary
            }

            let now = Date().timeIntervalSince1970
            let candidates: [(token: String, payload: [String: Any])] = tokenMatches.compactMap { match in
                guard let range = Range(match.range, in: jsContent) else { return nil }
                let token = String(jsContent[range])
                guard let decoded = payload(for: token) else { return nil }
                if let expiry = (decoded["exp"] as? NSNumber)?.doubleValue, expiry <= now + 60 {
                    return nil
                }
                return (token, decoded)
            }

            guard let selected = candidates.first(where: { $0.payload["iss"] as? String == "AMPWebPlay" })
                    ?? candidates.first else {
                await Logger.shared.log("[AppleMusicAPI] ⚠️ No current unexpired JWT found in JS bundle")
                return nil
            }

            self.cachedToken = selected.token
            let issuer = selected.payload["iss"] as? String ?? "unknown"
            await Logger.shared.log("[AppleMusicAPI] ✅ Current Apple Music JWT token selected issuer=\\(issuer) candidates=\\(candidates.count)")
            return selected.token
'''
if 'Current Apple Music JWT token selected' not in sms:
    token_start = sms.find('            let tokenPattern = #"eyJhbGciOi')
    token_return = sms.find('            return token\n', token_start)
    if token_start < 0 or token_return < 0:
        raise SystemExit('Apple Music token matcher anchor not found')
    token_end = token_return + len('            return token\n')
    sms = sms[:token_start] + new_token_block + sms[token_end:]
song_metadata.write_text(sms)

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
grep -Fq 'Current Apple Music JWT token selected' "$SONG_METADATA"
grep -Fq 'AMPWebPlay' "$SONG_METADATA"
! grep -Fq 'eyJhbGciOi[A-Za-z0-9_-]' "$SONG_METADATA"
! grep -Fq 'SplashView()' "$CONTENT"
! grep -Fq 'showSplash' "$CONTENT"
grep -Fq 'Text("Music Library")' ByeTunes/MusicManager/OnboardingView.swift
! grep -Fq 'Text("ByeTunes")' ByeTunes/MusicManager/OnboardingView.swift
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'idevice_init_logger('
# The explicit import/connect paths must remain present; this patch only removes
# automatic startup work.
grep -Fq 'func importPairingFile(from url: URL) throws' "$DEVICE"
grep -Fq 'func startHeartbeat(forceReconnect: Bool = false' "$DEVICE"
