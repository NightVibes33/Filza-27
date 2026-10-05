#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
TABS="$ROOT/TabViews.swift"
CONTENT="$ROOT/ContentView.swift"
ONBOARDING="$ROOT/OnboardingView.swift"
SETTINGS="$ROOT/SettingsView.swift"

for file in "$TABS" "$CONTENT" "$ONBOARDING" "$SETTINGS"; do
  test -s "$file" || { echo "missing ByeTunes UI source: $file" >&2; exit 1; }
done

python3 - "$TABS" "$CONTENT" "$ONBOARDING" "$SETTINGS" <<'PY'
from pathlib import Path
import sys

tabs = Path(sys.argv[1])
content = Path(sys.argv[2])
onboarding = Path(sys.argv[3])
settings = Path(sys.argv[4])

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

def replace_n(text: str, old: str, new: str, expected: int, label: str) -> str:
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} matches, found {count}")
    return text.replace(old, new)

# ---------------------------------------------------------------------------
# Remove the Download tab from both legacy and iOS 26+ tab shells.
# ---------------------------------------------------------------------------
s = tabs.read_text()

old_indices = '''    private var downloadTabIndex: Int { showRingtonesTab ? 2 : 1 }
    private var settingsTabIndex: Int { showRingtonesTab ? 3 : 2 }
'''
new_indices = '''    private var settingsTabIndex: Int { showRingtonesTab ? 2 : 1 }
'''
s = replace_n(s, old_indices, new_indices, 2, "tab index collapse")

legacy_download = '''                } else if selectedTab == downloadTabIndex {
                    DownloadView(songs: $songs, status: $status)
                } else {
'''
s = replace_once(s, legacy_download, '''                } else {
''', "legacy Download tab")

modern_download = '''            DownloadView(songs: $songs, status: $status)
                .tabItem {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tag(downloadTabIndex)
'''
s = replace_once(s, modern_download, "", "modern Download tab")

tabs.write_text(s)

# ---------------------------------------------------------------------------
# Remove download-only tutorial/deep-link routing and collapse the custom bar.
# ---------------------------------------------------------------------------
s = content.read_text()

download_index = '''    private var downloadTabIndex: Int {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let showRingtonesTab = (16...18).contains(major)
        return showRingtonesTab ? 2 : 1
    }
    
'''
s = replace_once(s, download_index, "", "ContentView download index")

tutorial = '''            if !showSplash && hasCompletedOnboarding && !tutorialComplete {
                TutorialOverlayView(
                    isComplete: $tutorialComplete,
                    songs: $songs,
                    selectedTab: $selectedTab,
                    downloadTabIndex: downloadTabIndex
                )
                .zIndex(1)
            }

'''
s = replace_once(s, tutorial, "", "download tutorial overlay")

old_open_url = '''        .onOpenURL { url in
            if url.scheme?.lowercased() == "byetunes" {
                let host = (url.host ?? "").lowercased()
                if host == "download" {
                    selectedTab = downloadTabIndex
                    return
                }
            }

            let host = (url.host ?? "").lowercased()
            if host.contains("spotify.com") || host.contains("music.apple.com") {
                if let normalized = LinkNormalizer.normalize(url) {
                    self.selectedTab = downloadTabIndex
                    NotificationCenter.default.post(name: NSNotification.Name("IncomingMusicLink"), object: normalized.normalizedURL.absoluteString)
                }
                return
            }

            if host.contains("deezer.com") || host.contains("deezer.page.link") {
                self.selectedTab = downloadTabIndex
                NotificationCenter.default.post(name: NSNotification.Name("IncomingMusicLink"), object: url.absoluteString)
                return
            }

            handleIncomingFile(url)
        }
'''
new_open_url = '''        .onOpenURL { url in
            let host = (url.host ?? "").lowercased()
            if url.scheme?.lowercased() == "byetunes" ||
               host.contains("spotify.com") ||
               host.contains("music.apple.com") ||
               host.contains("deezer.com") ||
               host.contains("deezer.page.link") {
                Logger.shared.log("[ContentView] Ignored download link because the Download tab is disabled")
                return
            }

            handleIncomingFile(url)
        }
'''
s = replace_once(s, old_open_url, new_open_url, "download deep-link routing")

floating_indices = '''    private var downloadTabIndex: Int { showRingtonesTab ? 2 : 1 }
    private var settingsTabIndex: Int { showRingtonesTab ? 3 : 2 }
'''
s = replace_once(s, floating_indices, '''    private var settingsTabIndex: Int { showRingtonesTab ? 2 : 1 }
''', "floating tab indices")

floating_download = '''            TabBarButton(
                icon: "arrow.down.circle",
                title: "Download",
                isSelected: selectedTab == downloadTabIndex
            ) {
                selectedTab = downloadTabIndex
            }
'''
s = replace_once(s, floating_download, "", "floating Download button")

content.write_text(s)

# ---------------------------------------------------------------------------
# Add NFCARD-style iOS 27 on-device pairing to onboarding.
# ---------------------------------------------------------------------------
s = onboarding.read_text()

manager_decl = '''    @ObservedObject var manager: DeviceManager
    @Binding var isComplete: Bool
'''
manager_new = '''    @ObservedObject var manager: DeviceManager
    @ObservedObject private var onDevicePairing = ByeTunesOnDevicePairingController.shared
    @Binding var isComplete: Bool
'''
if "ByeTunesOnDevicePairingController.shared" not in s:
    s = replace_once(s, manager_decl, manager_new, "onboarding pairing controller")

import_button_marker = '''                Button {
                    showingPairingPicker = true
                } label: {
'''
pairing_ui = '''                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                    VStack(spacing: 10) {
                        Button {
                            onDevicePairing.start(manager: manager)
                        } label: {
                            HStack(spacing: 8) {
                                if onDevicePairing.isPairing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "iphone.and.arrow.forward")
                                }
                                Text(onDevicePairing.isPairing ? "Pairing…" : "Pair This iPhone")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.accentColor)
                            )
                        }
                        .disabled(onDevicePairing.isPairing || isConnecting)

                        Text("Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes. Approve the pairing request, then return to ByeTunes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if let pin = onDevicePairing.pin {
                            Text("Pairing PIN: \(pin)")
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .textSelection(.enabled)
                        }

                        if onDevicePairing.isPairing || onDevicePairing.status != "Ready" {
                            Text(onDevicePairing.status)
                                .font(.caption)
                                .foregroundColor(onDevicePairing.status.contains("failed") || onDevicePairing.status.contains("Failed") ? .red : .secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack {
                            Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                            Text("OR IMPORT")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                            Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                        }
                    }
                }

'''
if "Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes" not in s:
    if import_button_marker not in s:
        raise SystemExit("onboarding import button marker missing")
    s = s.replace(import_button_marker, pairing_ui + import_button_marker, 1)

onboarding.write_text(s)

# ---------------------------------------------------------------------------
# Add the same pairing option in Settings and relabel the dead Downloads entry.
# ---------------------------------------------------------------------------
s = settings.read_text()

settings_manager = '''    @ObservedObject var manager: DeviceManager
    @Binding var status: String
'''
settings_manager_new = '''    @ObservedObject var manager: DeviceManager
    @ObservedObject private var onDevicePairing = ByeTunesOnDevicePairingController.shared
    @Binding var status: String
'''
if "private var onDevicePairing = ByeTunesOnDevicePairingController.shared" not in s:
    s = replace_once(s, settings_manager, settings_manager_new, "settings pairing controller")

first_divider = '''                        Divider().padding(.leading, 56)
'''
settings_pairing = '''                        Divider().padding(.leading, 56)

                        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                            Button {
                                onDevicePairing.start(manager: manager)
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.and.arrow.forward")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(onDevicePairing.isPairing ? "Pairing…" : "Pair This iPhone")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("Settings › Privacy & Security › Developer Mode › Pair with ByeTunes")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    if onDevicePairing.isPairing {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(Color(.systemGray3))
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                            .disabled(onDevicePairing.isPairing)

                            if let pin = onDevicePairing.pin {
                                Text("PIN \(pin) — enter it under Pair with ByeTunes")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider().padding(.leading, 56)
                        }
'''
if "Settings › Privacy & Security › Developer Mode › Pair with ByeTunes" not in s:
    s = replace_once(s, first_divider, settings_pairing, "settings on-device pairing row")

s = s.replace('Text("DOWNLOADS")', 'Text("METADATA & LYRICS")', 1)
s = s.replace('Text("Metadata & Download Settings")', 'Text("Metadata & Lyrics")', 1)
s = s.replace(
    'Text("Metadata source, downloader, quality, and saved downloads")',
    'Text("Metadata sources, Apple Music synced lyrics, and LRCLIB fallback")',
    1,
)

settings.write_text(s)
PY

grep -Fq 'Pair This iPhone' "$ONBOARDING"
grep -Fq 'Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes' "$ONBOARDING"
grep -Fq 'Pair This iPhone' "$SETTINGS"
grep -Fq 'Settings › Privacy & Security › Developer Mode › Pair with ByeTunes' "$SETTINGS"
grep -Fq 'Text("METADATA & LYRICS")' "$SETTINGS"
grep -Fq 'Text("Metadata & Lyrics")' "$SETTINGS"
! grep -Fq 'Label("Download", systemImage: "arrow.down.circle")' "$TABS"
! grep -Fq 'DownloadView(songs: $songs, status: $status)' "$TABS"
! grep -Fq 'title: "Download"' "$CONTENT"
! grep -Fq 'downloadTabIndex' "$CONTENT"
! grep -Fq 'downloadTabIndex' "$TABS"

echo "Applied ByeTunes on-device pairing UI and removed Download tab"
