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

device = Path(sys.argv[1])
content = Path(sys.argv[2])
settings = Path(sys.argv[3])
onboarding = Path(sys.argv[4])
compat = Path(sys.argv[5])
download = Path(sys.argv[6])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one upstream anchor, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# DeviceManager: preserve upstream v2.4 lifecycle. The only process-level
# adaptation is skipping idevice_init_logger because ByeTunes is not the owner
# of the Filza process. Keep upstream pairing fallback, state refresh, and the
# auto-reconnect watcher intact.
# ---------------------------------------------------------------------------
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
ds = replace_once(ds, old_init, new_init, "DeviceManager upstream lifecycle")

old_import_tail = '''        try FileManager.default.copyItem(at: url, to: expectedPairingFile)

        refreshExpectedPairingFileState()
'''
new_import_tail = '''        try FileManager.default.copyItem(at: url, to: expectedPairingFile)
        Logger.shared.log("[DeviceManager] Filza embed: imported pairing file persisted at \\(expectedPairingFile.path)")

        refreshExpectedPairingFileState()
'''
ds = replace_once(ds, old_import_tail, new_import_tail, "pairing import instrumentation")
device.write_text(ds)


# ---------------------------------------------------------------------------
# ContentView: remove only standalone-app concerns. Preserve upstream queue,
# pending-injection, reconnect, tutorial, URL handling, and scene lifecycle.
# Do NOT run cleanupLegacyImportedAudioFiles in Filza: upstream owns its own
# Documents directory, while an embedded module would otherwise delete audio
# files from Filza's Documents root.
# ---------------------------------------------------------------------------
cs = content.read_text()
cs = cs.replace("    @State private var showSplash = true\n", "")
cs = cs.replace("    @State private var availableUpdate: AppUpdateInfo?\n", "")
cs = cs.replace("    @State private var dismissedUpdateVersion: String?\n", "")

splash_open = '''            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
            
            if !showSplash {
                Group {
'''
cs = replace_once(cs, splash_open, "            Group {\n", "standalone splash wrapper")

splash_close = '''                }
            }

            if !showSplash && hasCompletedOnboarding && !tutorialComplete {
'''
cs = replace_once(cs, splash_close, '''            }

            if hasCompletedOnboarding && !tutorialComplete {
''', "standalone splash content close")
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
if update_overlay in cs:
    cs = cs.replace(update_overlay, "", 1)
elif "dismissedUpdateVersion != availableUpdate.version" in cs:
    raise SystemExit("standalone update overlay changed upstream")

old_appear_start = cs.find("        .onAppear {")
old_appear_end = cs.find("        .onOpenURL", old_appear_start)
if old_appear_start < 0 or old_appear_end < 0:
    raise SystemExit("ContentView onAppear boundary not found")
new_appear = '''        .onAppear {
            Logger.shared.log("[ContentView] Filza embed: upstream lifecycle onAppear entered")
            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile
            if manager.hasValidExpectedPairingFile {
                Logger.shared.log("[ContentView] Filza embed: restored persisted pairing file; reconnecting automatically")
                manager.startHeartbeat()
            } else {
                Logger.shared.log("[ContentView] Filza embed: no persisted pairing file; showing import flow")
            }

            // These are upstream v2.4 behaviors and must remain in the embed.
            restorePersistedSongQueueIfNeeded()
            checkPendingInjections()

            // Intentionally omitted from upstream standalone onAppear:
            // - cleanupLegacyImportedAudioFiles(): unsafe in Filza Documents.
            // - splash delay: Filza already owns app launch presentation.
            // - checkForAppUpdate(): standalone IPA updates do not apply here.
            Logger.shared.log("[Update] Filza embed: standalone ByeTunes updater disabled; updates are delivered with FilzaSlop")
        }
'''
cs = cs[:old_appear_start] + new_appear + cs[old_appear_end:]

update_function_start = cs.find("    private func checkForAppUpdate() {")
if update_function_start >= 0:
    update_function_end = cs.find("    private func attemptAutoReconnectIfNeeded()", update_function_start)
    if update_function_end < 0:
        raise SystemExit("checkForAppUpdate function boundary not found")
    cs = cs[:update_function_start] + cs[update_function_end:]

cs = cs.replace(
    "        guard scenePhase == .active, !showSplash, hasCompletedOnboarding else { return }",
    "        guard scenePhase == .active, hasCompletedOnboarding else { return }",
    1,
)
if "showSplash" in cs or "SplashView()" in cs:
    raise SystemExit("standalone splash still present after parity patch")
if "checkForAppUpdate()" in cs or "dismissedUpdateVersion" in cs:
    raise SystemExit("standalone update path still present after parity patch")
if "checkPendingInjections()" not in cs:
    raise SystemExit("upstream pending-injection lifecycle was lost")
content.write_text(cs)


# ---------------------------------------------------------------------------
# Settings/UI: disable only the standalone update action and retain the user's
# requested embedded naming. Leave the rest of upstream SettingsView untouched;
# metadata compatibility is applied later by its own narrowly scoped patch.
# ---------------------------------------------------------------------------
ss = settings.read_text()
ss = ss.replace("    @State private var isCheckingForUpdate = false\n", "")
ss = ss.replace("    @State private var settingsUpdate: AppUpdateInfo?\n", "")
version_start = ss.find('                        Button {\n                            if let settingsUpdate {')
version_end = ss.find("                        Divider().padding(.leading, 56)", version_start)
embedded_version_row = '''                        HStack {
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
if version_start >= 0 and version_end >= 0:
    ss = ss[:version_start] + embedded_version_row + ss[version_end:]
elif "Updates are delivered with FilzaSlop" not in ss:
    raise SystemExit("Settings version row anchor not found")

settings_update_start = ss.find("    private func checkForSettingsUpdate() {")
if settings_update_start >= 0:
    settings_update_end = ss.find("    private func showToastMessage", settings_update_start)
    if settings_update_end < 0:
        raise SystemExit("Settings updater function boundary not found")
    ss = ss[:settings_update_start] + ss[settings_update_end:]

ss = ss.replace('Text("Add ByeTunes Shortcut")', 'Text("Add Music Library Shortcut")')
settings.write_text(ss)

obs = onboarding.read_text()
obs = obs.replace('Text("ByeTunes")', 'Text("Music Library")')
onboarding.write_text(obs)


# ---------------------------------------------------------------------------
# Restore the exact pre-v2.4 provider-selection state machine. This is the
# original ByeTunes contract: metadataSource is a legacy migration hint while
# metadataSourcesJSON is the actual multi-provider state. Do not reinterpret
# Local/All in a second compatibility layer.
# ---------------------------------------------------------------------------
ct = compat.read_text()
start = ct.find("struct MetadataProviderSettings {")
end_marker = "\n}\n\nstruct YouTubeMetadataCandidate"
end = ct.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("MetadataProviderSettings structural boundary not found")
end += 2
original_settings = '''struct MetadataProviderSettings {
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
        if current.contains(source) {
            removeSource(source)
        } else {
            addSource(source)
        }
    }

    static func hasRemoteSource() -> Bool {
        selectedSources().contains(where: { $0.isRemote })
    }
}'''
ct = ct[:start] + original_settings + ct[end:]
compat.write_text(ct)


# This parity patch must never rewrite DownloadView. The later metadata patch
# may add only its All-Sources search compatibility; the old Filza progress and
# error lifecycle rewrite is intentionally retired.
dv = download.read_text()
for forbidden in (
    "let transportProgress = max(0, min(progress, 0.90))",
    "Terminal success: progress reached 100 only after validated file persistence",
    "Terminal failure: cleared active progress",
    "responseBodySummary(_ data: Data",
):
    if forbidden in dv:
        raise SystemExit(f"non-upstream DownloadView behavior still present before metadata compatibility: {forbidden}")

print("Applied upstream-first ByeTunes embed parity patch")
PY

grep -Fq 'installAutoReconnectWatcher()' "$DEVICE"
grep -Fq 'persistent pairing state restored=' "$DEVICE"
grep -Fq 'imported pairing file persisted at' "$DEVICE"
grep -Fq 'checkPendingInjections()' "$CONTENT"
grep -Fq 'upstream lifecycle onAppear entered' "$CONTENT"
! grep -Fq 'cleanupLegacyImportedAudioFiles()' <(grep -A30 -F '.onAppear {' "$CONTENT")
! grep -Fq 'SplashView()' "$CONTENT"
! grep -Fq 'checkForAppUpdate()' "$CONTENT"
grep -Fq 'Updates are delivered with FilzaSlop' "$SETTINGS"
grep -Fq 'Text("Music Library")' "$ONBOARDING"
grep -Fq 'static var safeSources' "$COMPAT"
grep -Fq 'if let legacy = UserDefaults.standard.string(forKey: legacySourceKey), legacy == "all"' "$COMPAT"
grep -Fq 'case "itunes": migrated = [.local, .itunes]' "$COMPAT"
! grep -Fq 'The visible Import Metadata Source picker is the single source of truth.' "$COMPAT"
! grep -Fq 'let transportProgress = max(0, min(progress, 0.90))' "$DOWNLOAD"

echo "Verified ByeTunes upstream-parity baseline before metadata restoration"
