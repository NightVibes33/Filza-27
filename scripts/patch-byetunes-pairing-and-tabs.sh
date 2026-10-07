#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
TABS="$ROOT/TabViews.swift"
CONTENT="$ROOT/ContentView.swift"
ONBOARDING="$ROOT/OnboardingView.swift"
TUTORIAL="$ROOT/TutorialOverlayView.swift"
SETTINGS="$ROOT/SettingsView.swift"
DEVICE="$ROOT/iDeviceManager.swift"
for file in "$TABS" "$CONTENT" "$ONBOARDING" "$TUTORIAL" "$SETTINGS" "$DEVICE"; do
  test -s "$file" || { echo "missing ByeTunes source: $file" >&2; exit 1; }
done

python3 - "$TABS" "$CONTENT" "$ONBOARDING" "$TUTORIAL" "$SETTINGS" "$DEVICE" <<'PY'
from pathlib import Path
import sys
tabs, content, onboarding, tutorial, settings, device = map(Path, sys.argv[1:])

def replace_once(text, old, new, label):
    count=text.count(old)
    if count != 1: raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old,new,1)

def balanced_end(text,start):
    brace=text.find("{",start)
    if brace < 0: raise SystemExit("opening brace missing")
    depth=0; quoted=False; escaped=False
    for i in range(brace,len(text)):
        c=text[i]
        if quoted:
            if escaped: escaped=False
            elif c=="\\": escaped=True
            elif c=='"': quoted=False
            continue
        if c=='"': quoted=True
        elif c=="{": depth+=1
        elif c=="}":
            depth-=1
            if depth==0: return i+1
    raise SystemExit("closing brace missing")

def trim(text,end):
    while end < len(text) and text[end] in " \t": end+=1
    if end < len(text) and text[end]=="\n": end+=1
    return end

def remove_block(text,marker):
    start=text.find(marker)
    if start < 0: return text
    return text[:start]+text[trim(text,balanced_end(text,start)):]

# Remove the Download tab.
s=tabs.read_text()
s=s.replace('''    private var downloadTabIndex: Int { showRingtonesTab ? 2 : 1 }
    private var settingsTabIndex: Int { showRingtonesTab ? 3 : 2 }
''','''    private var settingsTabIndex: Int { showRingtonesTab ? 2 : 1 }
''')
s=s.replace('''                } else if selectedTab == downloadTabIndex {
                    DownloadView(songs: $songs, status: $status)
                } else {
''','''                } else {
''',1)
s=s.replace('''            DownloadView(songs: $songs, status: $status)
                .tabItem {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tag(downloadTabIndex)
''',"",1)
s=s.replace('''            TabBarButton(
                icon: "arrow.down.circle",
                title: "Download",
                isSelected: selectedTab == downloadTabIndex
            ) {
                selectedTab = downloadTabIndex
            }
''',"",1)
tabs.write_text(s)

# ContentView: keep internal pairing-record persistence, remove every manual file picker/prompt.
s=content.read_text()
s=s.replace("    @State private var showingRPPairingUpgradePicker = false\n","")
s=s.replace("    @State private var rpPairingUpgradeError: String?\n","")
s=s.replace('''    private var downloadTabIndex: Int {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let showRingtonesTab = (16...18).contains(major)
        return showRingtonesTab ? 2 : 1
    }
    
''',"",1)
s=s.replace('''                TutorialOverlayView(
                    isComplete: $tutorialComplete,
                    songs: $songs,
                    selectedTab: $selectedTab,
                    downloadTabIndex: downloadTabIndex
                )
''','''                TutorialOverlayView(isComplete: $tutorialComplete)
''',1)
s=remove_block(s,"            if manager.shouldPromptForRPPairingUpgrade {")
s=remove_block(s,"        .sheet(isPresented: $showingRPPairingUpgradePicker) {")
s=remove_block(s,"    private func handleRPPairingUpgradeImport(url: URL?) {")
s=remove_block(s,"private struct RPPairingUpgradePrompt: View {")

old_reset='''        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ResetOnboardingFlow"))) { _ in
            hasCompletedOnboarding = false
        }
'''
if old_reset in s:
    s=s.replace(old_reset,'''        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ResetOnboardingFlow"))) { _ in
            tutorialComplete = false
        }
''',1)
show_logs='''        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowLogViewer"))) { _ in
            showingLogViewer = true
        }
'''
if "ReplayByeTunesOnboarding" not in s:
    s=replace_once(s,show_logs,show_logs+'''        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReplayByeTunesOnboarding"))) { _ in
            tutorialComplete = false
        }
''',"replay receiver")

open_start=s.find("        .onOpenURL { url in")
open_end=s.find("        .onChange(of: scenePhase)",open_start)
if open_start < 0 or open_end < 0: raise SystemExit("openURL block missing")
s=s[:open_start]+'''        .onOpenURL { url in
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
'''+s[open_end:]
s=s.replace("showing import flow","showing on-device pairing flow")
content.write_text(s)

onboarding.write_text(r'''import SwiftUI
import Combine

struct OnboardingView: View {
    @ObservedObject var manager: DeviceManager
    @ObservedObject private var onDevicePairing = ByeTunesOnDevicePairingController.shared
    @Binding var isComplete: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 24)
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundColor(.accentColor)
                    VStack(spacing: 8) {
                        Text("Music Library").font(.system(size: 32, weight: .bold))
                        Text("Pair this iPhone directly. Manual pairing-file import is no longer used.")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Turn on LocalDevVPN.", systemImage: "1.circle.fill")
                        Label("Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes.", systemImage: "2.circle.fill")
                        Label("Approve the request and enter the PIN shown here.", systemImage: "3.circle.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button { onDevicePairing.start(manager: manager) } label: {
                        HStack(spacing: 10) {
                            if onDevicePairing.isPairing { ProgressView().tint(.white) }
                            else { Image(systemName: "link") }
                            Text(onDevicePairing.isPairing ? "Pairing…" : "Pair This iPhone")
                        }
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
                    }
                    .disabled(onDevicePairing.isPairing)

                    if let pin = onDevicePairing.pin {
                        VStack(spacing: 4) {
                            Text("PAIRING PIN").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            Text(pin).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        }
                    }

                    Text(onDevicePairing.status)
                        .font(.caption)
                        .foregroundColor(onDevicePairing.status.localizedCaseInsensitiveContains("fail") ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24).padding(.bottom, 36)
            }
        }
        .onAppear {
            if manager.hasValidExpectedPairingFile { isComplete = true }
        }
        .onReceive(manager.$hasValidExpectedPairingFile.removeDuplicates()) { valid in
            guard valid else { return }
            manager.startHeartbeat(forceReconnect: true)
            isComplete = true
        }
    }
}
''')

tutorial.write_text(r'''import SwiftUI

struct TutorialOverlayView: View {
    @Binding var isComplete: Bool
    @State private var showingImportStep = false
    @AppStorage("appleRichMetadata") private var appleRichMetadata = true
    @AppStorage("autofetchMetadata") private var autofetchMetadata = true
    @AppStorage("fetchLyrics") private var fetchLyrics = false
    @AppStorage("appleSubscriptionLyrics") private var appleSubscriptionLyrics = false
    @AppStorage("metadataSource") private var metadataSource = "apple"

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: showingImportStep ? "square.and.arrow.down" : "music.note")
                    .font(.system(size: 34, weight: .semibold)).foregroundColor(.accentColor)
                if showingImportStep {
                    Text("Import and Inject").font(.title2.bold())
                    Text("Add an MP3, FLAC, M4A, WAV, AIFF, or Opus file from Files or the share sheet. Review it in Music, then tap Inject.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Done") { finish() }.buttonStyle(.borderedProminent)
                } else {
                    Text("Choose your metadata style").font(.title2.bold())
                    Text("You can change these options any time in Settings.")
                        .font(.subheadline).foregroundColor(.secondary)
                    Button {
                        appleRichMetadata = true
                        autofetchMetadata = true
                        fetchLyrics = false
                        appleSubscriptionLyrics = true
                        metadataSource = "apple"
                        showingImportStep = true
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Apple Music Style").font(.headline)
                            Text("Apple catalog metadata + native synced lyrics when a catalog match is available.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                    Button { showingImportStep = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Custom").font(.headline)
                            Text("Keep your current metadata and lyric settings.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                    Button("Skip tutorial") { finish() }.font(.subheadline).foregroundColor(.secondary)
                }
            }
            .padding(24).background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal, 20)
        }
    }

    private func finish() { withAnimation { isComplete = true } }
}
''')

# Settings connection card.
s=settings.read_text()
s=s.replace("    @State private var showingPairingPicker = false\n","")
manager='''    @ObservedObject var manager: DeviceManager
    @Binding var status: String
'''
if "ByeTunesOnDevicePairingController.shared" not in s:
    s=replace_once(s,manager,'''    @ObservedObject var manager: DeviceManager
    @ObservedObject private var onDevicePairing = ByeTunesOnDevicePairingController.shared
    @Binding var status: String
''',"settings controller")

old='''                        Button {
                            showingPairingPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "link")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manager.expectedPairingFileTitle)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(manager.connectionStatus)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
'''
new='''                        Button {
                            onDevicePairing.start(manager: manager)
                        } label: {
                            HStack {
                                Image(systemName: "iphone.and.arrow.forward")
                                    .font(.body).foregroundColor(.primary).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manager.hasValidExpectedPairingFile ? "Re-pair This iPhone" : "Pair This iPhone")
                                        .font(.body).foregroundColor(.primary)
                                    Text("Settings › Privacy & Security › Developer Mode › Pair with ByeTunes")
                                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if onDevicePairing.isPairing { ProgressView() }
                                else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundColor(Color(.systemGray3))
                                }
                            }
                            .padding(.vertical, 14).padding(.horizontal, 16)
                        }
                        .disabled(onDevicePairing.isPairing)

                        if let pin = onDevicePairing.pin {
                            Text("PIN \(pin)")
                                .font(.caption.weight(.semibold)).foregroundColor(.accentColor)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
'''
s=replace_once(s,old,new,"settings pairing row")

status=s.find('                            Text("Status")')
start=s.rfind("                        HStack {",0,status)
end=balanced_end(s,start)
tail='''                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
'''
tailPos=s.find(tail,end)
if status<0 or start<0 or tailPos<0: raise SystemExit("status row anchor missing")
insert=tailPos+len(tail)
if 'Text("Replay Onboarding")' not in s:
    replay='''
                        Divider().padding(.leading, 56)

                        Button {
                            NotificationCenter.default.post(name: NSNotification.Name("ReplayByeTunesOnboarding"), object: nil)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .font(.body).foregroundColor(.primary).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Replay Onboarding").font(.body).foregroundColor(.primary)
                                    Text("Show the tutorial again without removing pairing.")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14).padding(.horizontal, 16)
                        }
'''
    s=s[:insert]+replay+s[insert:]

s=remove_block(s,"        .sheet(isPresented: $showingPairingPicker) {")
s=remove_block(s,"    func handlePairingImport(url: URL?) {")
s=s.replace('Text("DOWNLOADS")','Text("METADATA & LYRICS")',1)
s=s.replace('Text("Metadata & Download Settings")','Text("Metadata & Lyrics")',1)
s=s.replace('Text("Metadata source, downloader, quality, and saved downloads")','Text("Metadata sources and lyric behavior")',1)
settings.write_text(s)

ds=device.read_text()
ds=ds.replace("Import your RP Pairing File first.","Pair this iPhone first.")
ds=ds.replace("Import the correct file before connecting.","Pair this iPhone before connecting.")
device.write_text(ds)
PY

grep -Fq 'Pair with ByeTunes' "$ONBOARDING"
grep -Fq 'Pair This iPhone' "$ONBOARDING"
grep -Fq 'Replay Onboarding' "$SETTINGS"
grep -Fq 'ReplayByeTunesOnboarding' "$CONTENT"
! grep -Fq 'showingPairingPicker' "$ONBOARDING"
! grep -Fq 'showingPairingPicker' "$SETTINGS"
! grep -Fq 'Import RP Pairing File' "$CONTENT"
! grep -Fq 'RPPairingUpgradePrompt' "$CONTENT"
! grep -Fq 'downloadTabIndex' "$CONTENT"
! grep -Fq 'downloadTabIndex' "$TABS"
echo "Applied on-device-only pairing and replayable onboarding"
