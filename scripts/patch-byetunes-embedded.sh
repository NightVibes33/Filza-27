#!/bin/bash
set -euo pipefail

DEVICE="ByeTunes/MusicManager/iDeviceManager.swift"
CONTENT="ByeTunes/MusicManager/ContentView.swift"
SONG_METADATA="ByeTunes/MusicManager/SongMetadata.swift"
SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
DOWNLOAD_VIEW="ByeTunes/MusicManager/DownloadView.swift"
test -f "$DEVICE"
test -f "$CONTENT"
test -f "$SONG_METADATA"
test -f "$SETTINGS"
test -f "$DOWNLOAD_VIEW"

python3 - "$DEVICE" "$CONTENT" "$SONG_METADATA" "$SETTINGS" "$DOWNLOAD_VIEW" <<'PY'
from pathlib import Path
import re
import sys

device = Path(sys.argv[1])
content = Path(sys.argv[2])
song_metadata = Path(sys.argv[3])
settings = Path(sys.argv[4])
download_view = Path(sys.argv[5])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old in text:
        return text.replace(old, new, 1)
    if new in text:
        return text
    raise SystemExit(f"{label} anchor not found")


ds = device.read_text()

# Filza does not own ByeTunes' application-group entitlement. Keep the embedded
# pairing copy in Filza's persistent Documents container so it survives process
# relaunches and can be reused without reopening the document picker.
pairing_property_start = ds.find("    var regularPairingFile: URL {")
pairing_property_end = ds.find("\n    var rpPairingFile: URL {", pairing_property_start)
if pairing_property_start < 0 or pairing_property_end < 0:
    raise SystemExit("DeviceManager regularPairingFile property not found")
persistent_pairing_property = '''    var regularPairingFile: URL {
        URL.documentsDirectory
            .appendingPathComponent("pairing file", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }
'''
ds = ds[:pairing_property_start] + persistent_pairing_property + ds[pairing_property_end:]

init_start = ds.find("    private init() {")
if init_start < 0:
    raise SystemExit("DeviceManager private init not found")
init_end = ds.find("\n    private func ", init_start)
if init_end < 0:
    raise SystemExit("DeviceManager private init end not found")

# Filza owns the process. DeviceManager.shared is created while SwiftUI builds
# ContentView, so its embedded initializer must not touch process-global FFI,
# sockets, timers, or tunnel state. Restoring the saved pairing file's local
# state is intentionally safe and required across app launches.
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
# data writes handle selecting the already-saved file and avoid leaving a
# missing or partial pairing file if the process is interrupted during import.
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
elif "Filza embed: imported pairing file persisted at" not in ds:
    raise SystemExit("DeviceManager pairing import write anchor not found")
device.write_text(ds)


cs = re.sub(r"^[ \t]+$", "", content.read_text(), flags=re.MULTILINE)
cs = cs.replace("    @State private var showSplash = true\n", "")
cs = cs.replace("    @State private var availableUpdate: AppUpdateInfo?\n", "")
cs = cs.replace("    @State private var dismissedUpdateVersion: String?\n", "")

splash_wrapper = '''            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if !showSplash {
                Group {
'''
cs = replace_once(cs, splash_wrapper, "            Group {\n", "embedded 2.4 splash wrapper")

group_wrapper_end = '''                }
            }

            if !showSplash && hasCompletedOnboarding && !tutorialComplete {
'''
cs = replace_once(
    cs,
    group_wrapper_end,
    '''            }

            if hasCompletedOnboarding && !tutorialComplete {
''',
    "embedded 2.4 content wrapper",
)
cs = cs.replace(
    "            if !showSplash && manager.shouldPromptForRPPairingUpgrade {\n",
    "            if manager.shouldPromptForRPPairingUpgrade {\n",
    1,
)

# A standalone ByeTunes release cannot update an embedded module. Remove the
# automatic release overlay and its network check; FilzaSlop's IPA owns updates.
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
    raise SystemExit("embedded standalone update overlay changed unexpectedly")

new_appear = '''        .onAppear {
            // Filza embed: render immediately, restore local queue/pairing
            // state, and reconnect only after the view exists. The standalone
            // splash, cleanup pass, app-group startup, and IPA updater do not
            // belong to Filza's process lifecycle.
            Logger.shared.log("[ContentView] Filza embed: immediate safe onAppear entered")
            manager.refreshExpectedPairingFileState()
            hasCompletedOnboarding = manager.hasValidExpectedPairingFile
            restorePersistedSongQueueIfNeeded()
            if manager.hasValidExpectedPairingFile {
                Logger.shared.log("[ContentView] Filza embed: restored persisted pairing file; reconnecting automatically")
                manager.startHeartbeat()
            } else {
                Logger.shared.log("[ContentView] Filza embed: no persisted pairing file; showing import flow")
            }
            Logger.shared.log("[Update] Filza embed: standalone ByeTunes updater disabled; updates are delivered with FilzaSlop")
        }
'''
appear_start = cs.find("        .onAppear {")
appear_end = cs.find("        .onOpenURL", appear_start)
if appear_start < 0 or appear_end < 0:
    raise SystemExit("embedded ContentView onAppear anchor not found")
cs = cs[:appear_start] + new_appear + cs[appear_end:]

update_function_start = cs.find("    private func checkForAppUpdate() {")
if update_function_start >= 0:
    update_function_end = cs.find("    private func attemptAutoReconnectIfNeeded()", update_function_start)
    if update_function_end < 0:
        raise SystemExit("embedded ContentView update function end not found")
    cs = cs[:update_function_start] + cs[update_function_end:]

cs = cs.replace(
    "        guard scenePhase == .active, !showSplash, hasCompletedOnboarding else { return }",
    "        guard scenePhase == .active, hasCompletedOnboarding else { return }",
    1,
)
if "showSplash" in cs or "SplashView()" in cs:
    raise SystemExit("embedded splash route was not fully removed")
if "checkForAppUpdate()" in cs or "dismissedUpdateVersion" in cs:
    raise SystemExit("embedded standalone update route was not fully removed")
content.write_text(cs)


# ByeTunes 2.4 replaced the brittle web-player JWT scraper with public Apple
# catalog-page parsing. Keep that upstream implementation intact and fail the
# build if an older token-scraping source is pinned by mistake.
sms = song_metadata.read_text()
if "Public search page fallback" not in sms or "actor AppleMusicAPI" not in sms:
    raise SystemExit("ByeTunes 2.4 public Apple Music search implementation not found")
song_metadata.write_text(sms)


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
    raise SystemExit("ByeTunes Settings version row anchor not found")

settings_update_start = ss.find("    private func checkForSettingsUpdate() {")
if settings_update_start >= 0:
    settings_update_end = ss.find("    private func showToastMessage", settings_update_start)
    if settings_update_end < 0:
        raise SystemExit("ByeTunes Settings update function end not found")
    ss = ss[:settings_update_start] + ss[settings_update_end:]

visible_replacements = [
    ('Text("Add ByeTunes Shortcut")', 'Text("Add Music Library Shortcut")'),
]
for old, new in visible_replacements:
    if old not in ss and new not in ss:
        raise SystemExit(f"visible branding anchor not found in SettingsView: {old}")
    ss = ss.replace(old, new)
settings.write_text(ss)

onboarding = Path("ByeTunes/MusicManager/OnboardingView.swift")
onboarding_text = onboarding.read_text()
if 'Text("ByeTunes")' in onboarding_text:
    onboarding_text = onboarding_text.replace('Text("ByeTunes")', 'Text("Music Library")')
elif 'Text("Music Library")' not in onboarding_text:
    raise SystemExit("visible branding anchor not found in OnboardingView")
onboarding.write_text(onboarding_text)


# Transport completion is not song completion. URLSession can finish receiving
# an HTML/JSON error body and report 100% before validateHTTP rejects it. Cap
# visible transport progress below 100, reset it for each fallback, and publish
# 100 only after the final audio file and metadata have been validated/persisted.
dvs = download_view.read_text()

old_progress_update = '''    private func updateVisibleDownloadProgress(_ progress: Double, speedBps: Double) {
        currentSongProgress = progress
        currentDownloadSpeedBps = speedBps

        guard let activeID = activeDownloadTrackID, let track = knownTracksByID[activeID] else { return }
        updateLiveActivity(
            trackName: track.name,
            artistName: track.artistLine,
            progress: progress,
'''
new_progress_update = '''    private func updateVisibleDownloadProgress(_ progress: Double, speedBps: Double) {
        guard let activeID = activeDownloadTrackID, let track = knownTracksByID[activeID] else { return }
        let transportProgress = max(0, min(progress, 0.90))
        currentSongProgress = transportProgress
        currentDownloadSpeedBps = speedBps

        updateLiveActivity(
            trackName: track.name,
            artistName: track.artistLine,
            progress: transportProgress,
'''
dvs = replace_once(dvs, old_progress_update, new_progress_update, "visible download progress cap")

old_candidate_loop = '''        for candidate in candidates {
            do {
'''
new_candidate_loop = '''        for candidate in candidates {
            currentSongProgress = 0
            currentDownloadSpeedBps = 0
            do {
'''
dvs = replace_once(dvs, old_candidate_loop, new_candidate_loop, "download candidate reset")

old_candidate_failure = '''            } catch {
                lastError = error
                log("\\(candidate.label) backend failed: \\(error.localizedDescription)")
                BackendHealthStore.shared.recordFailure(label: candidate.label, error: error.localizedDescription)
            }
'''
new_candidate_failure = '''            } catch {
                lastError = error
                currentSongProgress = 0
                currentDownloadSpeedBps = 0
                log("\\(candidate.label) backend failed: \\(error.localizedDescription)")
                BackendHealthStore.shared.recordFailure(label: candidate.label, error: error.localizedDescription)
            }
'''
dvs = replace_once(dvs, old_candidate_failure, new_candidate_failure, "download candidate failure reset")

old_finalizer = '''        var song = try await SongMetadata.fromURL(fileURL)
        try await validateDownloadedSong(song, sourceTrack: track, backendLabel: backendLabel)
        if backgroundDownloadsEnabled {
            trackStates[track.id] = .done
            handOffDownloadedFileForMainImport(song.localURL, trackID: track.id)
            log("Queued downloaded file for main import pipeline: \\(song.title) [\\(track.id)]")
        } else {
            song = await enrichDownloadedSong(song, sourceTrack: track)
            song = persistDownloadedSongIfNeeded(song)
            emittedSongs.append(song)
            trackStates[track.id] = .done
            log("Track finished with immediate metadata enrichment: \\(song.title) [\\(track.id)]")
        }
'''
new_finalizer = '''        currentSongProgress = max(currentSongProgress, 0.92)
        var song = try await SongMetadata.fromURL(fileURL)
        currentSongProgress = max(currentSongProgress, 0.94)
        try await validateDownloadedSong(song, sourceTrack: track, backendLabel: backendLabel)
        currentSongProgress = max(currentSongProgress, 0.96)
        if backgroundDownloadsEnabled {
            handOffDownloadedFileForMainImport(song.localURL, trackID: track.id)
            currentSongProgress = 1
            trackStates[track.id] = .done
            log("Terminal success: progress reached 100 only after validated background handoff for \\(song.title) [\\(track.id)]")
        } else {
            song = await enrichDownloadedSong(song, sourceTrack: track)
            currentSongProgress = max(currentSongProgress, 0.98)
            song = persistDownloadedSongIfNeeded(song)
            currentSongProgress = 0.99
            emittedSongs.append(song)
            currentSongProgress = 1
            trackStates[track.id] = .done
            log("Terminal success: progress reached 100 only after validated file persistence for \\(song.title) [\\(track.id)]")
        }
'''
dvs = replace_once(dvs, old_finalizer, new_finalizer, "download terminal success contract")

old_main_failure = '''                let message = downloadFailureMessage(for: track, error: error)
                log("Download failed: \\(message)")
                errorText = message
                trackFailureReasons[track.id] = message
                trackStates[track.id] = .failed
'''
new_main_failure = '''                let message = downloadFailureMessage(for: track, error: error)
                currentSongProgress = 0
                currentDownloadSpeedBps = 0
                log("Download failed: \\(message)")
                log("Terminal failure: cleared active progress for \\(track.name) [\\(track.id)]")
                errorText = message
                trackFailureReasons[track.id] = message
                trackStates[track.id] = .failed
'''
dvs = replace_once(dvs, old_main_failure, new_main_failure, "foreground terminal failure contract")

old_http_validation = '''    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw DownloadError.httpError(http.statusCode, body)
        }
    }
'''
new_http_validation = '''    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.httpError(http.statusCode, responseBodySummary(data))
        }
    }

    private func responseBodySummary(_ data: Data, limit: Int = 512) -> String {
        let prefix = data.prefix(limit)
        let decoded = String(data: prefix, encoding: .utf8) ?? "<non-utf8 body>"
        let collapsed = decoded.replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return data.count > limit ? "\\(collapsed)…" : collapsed
    }
'''
dvs = replace_once(dvs, old_http_validation, new_http_validation, "bounded HTTP error body")

old_json_failure = '''            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 json>"
            throw DownloadError.remoteFailure(bodyText)
'''
new_json_failure = '''            throw DownloadError.remoteFailure(responseBodySummary(data))
'''
dvs = replace_once(dvs, old_json_failure, new_json_failure, "bounded JSON error body")

old_fetch_completion = '''        if let progressHandler {
            DispatchQueue.main.async {
                progressHandler(1, self.smoothedSpeedBps)
            }
        }
        continuation?.resume(returning: (receivedData, response))
'''
new_fetch_completion = '''        // Receiving a response body is only transport completion. HTTP and
        // audio validation happen after this continuation resumes, so 100%
        // must be reserved for the terminal success path in the view model.
        continuation?.resume(returning: (receivedData, response))
'''
dvs = replace_once(dvs, old_fetch_completion, new_fetch_completion, "premature transport completion")

download_view.write_text(dvs)
PY

grep -Fq 'private let BUILD_VERSION = "v2.4"' "$DEVICE"
grep -Fq 'Filza embed: inert startup initialized' "$DEVICE"
grep -Fq 'URL.documentsDirectory' "$DEVICE"
grep -Fq 'persistent pairing state restored=' "$DEVICE"
grep -Fq 'imported pairing file persisted at' "$DEVICE"
grep -Fq 'Filza embed: immediate safe onAppear entered' "$CONTENT"
grep -Fq 'restored persisted pairing file; reconnecting automatically' "$CONTENT"
grep -Fq 'standalone ByeTunes updater disabled' "$CONTENT"
grep -Fq 'static let currentVersion = "2.4"' "$CONTENT"
! grep -Fq 'SplashView()' "$CONTENT"
! grep -Fq 'showSplash' "$CONTENT"
! grep -Fq 'checkForAppUpdate()' "$CONTENT"
grep -Fq 'Public search page fallback' "$SONG_METADATA"
grep -Fq 'Updates are delivered with FilzaSlop' "$SETTINGS"
grep -Fq 'ByeTunes 2.4' "$SETTINGS"
! grep -Fq 'Tap to check for updates' "$SETTINGS"
! grep -Fq 'checkForSettingsUpdate()' "$SETTINGS"
grep -Fq 'Text("Music Library")' ByeTunes/MusicManager/OnboardingView.swift
! grep -Fq 'Text("ByeTunes")' ByeTunes/MusicManager/OnboardingView.swift
grep -Fq 'let transportProgress = max(0, min(progress, 0.90))' "$DOWNLOAD_VIEW"
grep -Fq 'Terminal success: progress reached 100 only after validated file persistence' "$DOWNLOAD_VIEW"
grep -Fq 'Terminal failure: cleared active progress' "$DOWNLOAD_VIEW"
grep -Fq 'responseBodySummary' "$DOWNLOAD_VIEW"
! grep -Fq 'progressHandler(1, self.smoothedSpeedBps)' "$DOWNLOAD_VIEW"
! grep -A14 -F 'private init() {' "$DEVICE" | grep -Fq 'idevice_init_logger('
# Explicit import/connect and every 2.4 queue/backup implementation remain;
# this patch only adapts process ownership and terminal progress semantics.
grep -Fq 'func importPairingFile(from url: URL) throws' "$DEVICE"
grep -Fq 'func startHeartbeat(forceReconnect: Bool = false' "$DEVICE"
grep -Fq 'final class BackgroundAudioDownloadManager' ByeTunes/MusicManager/BackgroundAudioDownloadManager.swift
grep -Fq 'struct DeviceLibraryBrowserView' ByeTunes/MusicManager/DeviceLibraryBrowserView.swift
grep -Fq 'struct BackupRestoreView' ByeTunes/MusicManager/BackupRestoreView.swift
