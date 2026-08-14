#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
CONTENT="ByeTunes/MusicManager/ContentView.swift"
SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
ONBOARDING="ByeTunes/MusicManager/OnboardingView.swift"
COMPAT="ByeTunesMetadataCompat.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"

for path in "$DEVICE" "$CONTENT" "$SETTINGS" "$ONBOARDING" "$COMPAT" "$DOWNLOAD"; do
    test -f "$path"
done

python3 - "$DEVICE" "$CONTENT" "$SETTINGS" "$ONBOARDING" "$COMPAT" "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys

device, content, settings, onboarding, compat, download = map(Path, sys.argv[1:])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def remove_braced_function(text: str, signature: str, label: str) -> str:
    start = text.find(signature)
    if start < 0:
        return text
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"{label}: opening brace not found")
    depth = 0
    in_string = False
    escape = False
    i = brace
    while i < len(text):
        c = text[i]
        if in_string:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_string = False
        else:
            if c == '"':
                in_string = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    while end < len(text) and text[end] in " \t":
                        end += 1
                    if end < len(text) and text[end] == "\n":
                        end += 1
                    return text[:start] + text[end:]
        i += 1
    raise SystemExit(f"{label}: closing brace not found")


# DeviceManager: preserve upstream v2.4 initialization and auto reconnect.
# Only skip idevice_init_logger because ByeTunes is embedded in Filza's process.
ds = device.read_text()
old_init = '''    private init() {
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] BUILD VERSION: \\(BUILD_VERSION)")
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] Initializing...")
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("idevice-logs.txt").path
        let cString = strdup(logPath)
        defer { free(cString) }
        idevice_init_logger(Info, Disabled, cString)
        
        let folderPath = self.regularPairingFile.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: folderPath.path) {
                try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
                Logger.shared.log("[DeviceManager] Created pairing file directory at: \\(folderPath.path)")
            }
        } catch {
            Logger.shared.log("[DeviceManager] Error creating pairing directory: \\(error)")
        }
        refreshExpectedPairingFileState()
        installAutoReconnectWatcher()
    }
'''
new_init = '''    private init() {
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] BUILD VERSION: \\(BUILD_VERSION)")
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] Initializing embedded upstream lifecycle")
        Logger.shared.log("[DeviceManager] Filza embed: skipped process-global idevice logger initialization")

        let folderPath = self.regularPairingFile.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: folderPath.path) {
                try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
                Logger.shared.log("[DeviceManager] Created pairing file directory at: \\(folderPath.path)")
            }
        } catch {
            Logger.shared.log("[DeviceManager] Error creating pairing directory: \\(error)")
        }
        refreshExpectedPairingFileState()
        Logger.shared.log("[DeviceManager] Filza embed: persistent pairing state restored=\\(hasValidExpectedPairingFile) path=\\(expectedPairingFile.path)")
        installAutoReconnectWatcher()
    }
'''
ds = replace_once(ds, old_init, new_init, "DeviceManager init")
ds = replace_once(
    ds,
    '''        try FileManager.default.copyItem(at: url, to: expectedPairingFile)\n\n        refreshExpectedPairingFileState()\n''',
    '''        try FileManager.default.copyItem(at: url, to: expectedPairingFile)\n        Logger.shared.log("[DeviceManager] Filza embed: imported pairing file persisted at \\(expectedPairingFile.path)")\n\n        refreshExpectedPairingFileState()\n''',
    "pairing import instrumentation",
)
device.write_text(ds)


# ContentView: remove standalone splash/updater only. Retain upstream reconnect,
# persisted queue and pending-injection behavior. Do not run legacy audio cleanup
# because embedded URL.documentsDirectory is Filza's Documents directory.
cs = content.read_text()
for state in (
    "    @State private var showSplash = true\n",
    "    @State private var availableUpdate: AppUpdateInfo?\n",
    "    @State private var dismissedUpdateVersion: String?\n",
):
    cs = cs.replace(state, "")

cs = replace_once(
    cs,
    '''            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
            
            if !showSplash {
                Group {
''',
    "            Group {\n",
    "splash wrapper open",
)
cs = replace_once(
    cs,
    '''                }
            }

            if !showSplash && hasCompletedOnboarding && !tutorialComplete {
''',
    '''            }

            if hasCompletedOnboarding && !tutorialComplete {
''',
    "splash wrapper close",
)
cs = cs.replace(
    '            if !showSplash && manager.shouldPromptForRPPairingUpgrade {\n',
    '            if manager.shouldPromptForRPPairingUpgrade {\n',
    1,
)

update_overlay = '''            if !showSplash,
               let availableUpdate,
               dismissedUpdateVersion != availableUpdate.version {
                AppUpdatePrompt(
                    update: availableUpdate,
                    dismissAction: {
                        dismissedUpdateVersion = availableUpdate.version
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(3)
            }
'''
cs = replace_once(cs, update_overlay, "", "standalone update overlay")

appear_start = cs.find("        .onAppear {")
appear_end = cs.find("        .onOpenURL", appear_start)
if appear_start < 0 or appear_end < 0:
    raise SystemExit("ContentView onAppear boundary not found")
cs = cs[:appear_start] + '''        .onAppear {
            Logger.shared.log("[ContentView] Filza embed: upstream lifecycle onAppear entered")
            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile
            if manager.hasValidExpectedPairingFile {
                Logger.shared.log("[ContentView] Filza embed: restored persisted pairing file; reconnecting automatically")
                manager.startHeartbeat()
            } else {
                Logger.shared.log("[ContentView] Filza embed: no persisted pairing file; showing import flow")
            }
            restorePersistedSongQueueIfNeeded()
            checkPendingInjections()
            Logger.shared.log("[Update] Filza embed: standalone ByeTunes updater disabled; updates are delivered with FilzaSlop")
        }
''' + cs[appear_end:]

cs = remove_braced_function(cs, "    private func checkForAppUpdate() {", "ContentView updater")
cs = cs.replace(
    "        guard scenePhase == .active, !showSplash, hasCompletedOnboarding else { return }",
    "        guard scenePhase == .active, hasCompletedOnboarding else { return }",
    1,
)
if "showSplash" in cs or "SplashView()" in cs:
    raise SystemExit("standalone splash symbol remains")
if "    private func checkForAppUpdate() {" in cs or "\n            checkForAppUpdate()\n" in cs:
    raise SystemExit("live standalone updater remains")
if "dismissedUpdateVersion" in cs:
    raise SystemExit("standalone updater state remains")
if "checkPendingInjections()" not in cs or "restorePersistedSongQueueIfNeeded()" not in cs:
    raise SystemExit("upstream queue/pending lifecycle missing")
content.write_text(cs)


# Settings: remove only the standalone update control/function. Use structural
# function removal so unrelated settings helpers can never be swallowed.
ss = settings.read_text()
ss = ss.replace("    @State private var isCheckingForUpdate = false\n", "")
ss = ss.replace("    @State private var settingsUpdate: AppUpdateInfo?\n", "")
version_start = ss.find('                        Button {\n                            if let settingsUpdate {')
version_end = ss.find("                        Divider().padding(.leading, 56)", version_start)
if version_start < 0 or version_end < 0:
    raise SystemExit("Settings version row boundary not found")
version_row = '''                        HStack {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text("Updates are delivered with FilzaSlop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("ByeTunes 2.4")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)

'''
ss = ss[:version_start] + version_row + ss[version_end:]
ss = remove_braced_function(ss, "    private func checkForSettingsUpdate() {", "Settings updater")
ss = ss.replace('Text("Add ByeTunes Shortcut")', 'Text("Add Music Library Shortcut")')
if "checkForSettingsUpdate()" in ss or "settingsUpdate" in ss or "isCheckingForUpdate" in ss:
    raise SystemExit("live Settings updater remains")
settings.write_text(ss)

obs = onboarding.read_text().replace('Text("ByeTunes")', 'Text("Music Library")')
onboarding.write_text(obs)


# Exact pre-v2.4 provider-selection state machine.
ct = compat.read_text()
start = ct.find("struct MetadataProviderSettings {")
end_marker = "\n}\n\nstruct YouTubeMetadataCandidate"
end = ct.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("MetadataProviderSettings boundary not found")
end += 2
original = '''struct MetadataProviderSettings {
    static let sourcesKey = "metadataSourcesJSON"
    static let legacySourceKey = "metadataSource"

    static var defaultSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer, .apple]
    }

    static var safeSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer]
    }

    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()
        if let legacy = UserDefaults.standard.string(forKey: legacySourceKey), legacy == "all" {
            return defaultSources
        }
        guard let json = UserDefaults.standard.string(forKey: sourcesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MetadataProviderID].self, from: data) else {
            return [.local]
        }
        return decoded.isEmpty ? [.local] : decoded
    }

    static func saveSources(_ sources: [MetadataProviderID]) {
        let valid = sources.isEmpty ? [MetadataProviderID.local] : sources
        if let data = try? JSONEncoder().encode(valid),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: sourcesKey)
        }
    }

    static func migrateIfNeeded() {
        guard UserDefaults.standard.string(forKey: sourcesKey) == nil else { return }
        let old = UserDefaults.standard.string(forKey: legacySourceKey) ?? "local"
        let migrated: [MetadataProviderID]
        switch old {
        case "youtube": migrated = [.local, .youtube]
        case "itunes": migrated = [.local, .itunes]
        case "deezer": migrated = [.local, .deezer]
        case "apple": migrated = [.local, .apple]
        case "all": migrated = defaultSources
        default: migrated = [.local]
        }
        saveSources(migrated)
    }

    static func addSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        if !current.contains(source) {
            current.append(source)
            saveSources(current)
        }
    }

    static func removeSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        current.removeAll { $0 == source }
        if current.isEmpty { current = [.local] }
        saveSources(current)
    }

    static func toggleSource(_ source: MetadataProviderID) {
        let current = selectedSources()
        if current.contains(source) { removeSource(source) }
        else { addSource(source) }
    }

    static func hasRemoteSource() -> Bool {
        selectedSources().contains(where: { $0.isRemote })
    }
}'''
ct = ct[:start] + original + ct[end:]
compat.write_text(ct)

# No DownloadView progress/error rewrite belongs in this host parity layer.
dv = download.read_text()
for forbidden in (
    "let transportProgress = max(0, min(progress, 0.90))",
    "Terminal success: progress reached 100 only after validated file persistence",
    "Terminal failure: cleared active progress",
    "responseBodySummary(_ data: Data",
):
    if forbidden in dv:
        raise SystemExit(f"retired DownloadView rewrite present: {forbidden}")

print("Applied structural upstream-first ByeTunes parity v2")
PY

grep -Fq 'installAutoReconnectWatcher()' "$DEVICE"
grep -Fq 'persistent pairing state restored=' "$DEVICE"
grep -Fq 'imported pairing file persisted at' "$DEVICE"
grep -Fq 'checkPendingInjections()' "$CONTENT"
grep -Fq 'restorePersistedSongQueueIfNeeded()' "$CONTENT"
grep -Fq 'upstream lifecycle onAppear entered' "$CONTENT"
! grep -Fq 'SplashView()' "$CONTENT"
! grep -Fq '    private func checkForAppUpdate() {' "$CONTENT"
grep -Fq 'Updates are delivered with FilzaSlop' "$SETTINGS"
grep -Fq 'Text("Music Library")' "$ONBOARDING"
grep -Fq 'static var safeSources' "$COMPAT"
grep -Fq 'case "itunes": migrated = [.local, .itunes]' "$COMPAT"
! grep -Fq 'The visible Import Metadata Source picker is the single source of truth.' "$COMPAT"
! grep -Fq 'let transportProgress = max(0, min(progress, 0.90))' "$DOWNLOAD"

echo "Verified structural ByeTunes upstream-parity baseline"
