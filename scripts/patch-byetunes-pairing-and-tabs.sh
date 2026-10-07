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
''','''                TutorialOverlayView(isComplete: $tutorialComplete, songs: $songs, selectedTab: $selectedTab)
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
            hasCompletedOnboarding = false
            tutorialComplete = false
            selectedTab = 0
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

# Keep upstream's animated onboarding and replace only its connection controls.
s=onboarding.read_text()
s=replace_once(s,'    @ObservedObject var manager: DeviceManager\n','    @ObservedObject var manager: DeviceManager\n    @ObservedObject private var onDevicePairing = ByeTunesOnDevicePairingController.shared\n','onboarding pairing controller')
s=s.replace('    @State private var showingPairingPicker = false\n','')
s=remove_block(s,'        .sheet(isPresented: $showingPairingPicker) {')
s=remove_block(s,'    func handlePairingImport(url: URL?) {')
s=s.replace('    // MARK: - Pairing Import\n','    // MARK: - Reconnect\n')
a=s.index('                StepRow(number: "1"');b=s.index('\n            }',a)
s=s[:a]+'''                StepRow(number: "1", text: "Turn on LocalDevVPN", isLast: false)
                StepRow(number: "2", text: "Tap Pair This iPhone below", isLast: false)
                StepRow(number: "3", text: "Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes", isLast: false)
                StepRow(number: "4", text: "Approve the request and enter the PIN shown here", isLast: true)'''+s[b:]
s=replace_once(s,'                    showingPairingPicker = true','''                    isConnecting = true
                    showError = false
                    statusMessage = "Starting on-device pairing…"
                    onDevicePairing.start(manager: manager)''','onboarding action')
s=s.replace('Text("Import \\(manager.expectedPairingFileTitle)")','Text(onDevicePairing.isPairing ? "Pairing…" : "Pair This iPhone")')
s=s.replace('Image(systemName: "arrow.up.doc.fill")','Image(systemName: "iphone.and.arrow.forward")')
marker='                if showError && manager.hasValidExpectedPairingFile {'
extra='''                if let pin = onDevicePairing.pin {
                    Text("Pairing PIN: \\(pin)")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                }

                if manager.heartbeatReady {
                    Button("Continue") { withAnimation { isComplete = true } }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }

'''
s=replace_once(s,marker,extra+marker,'onboarding PIN and replay continuation')
marker='        .onChange(of: manager.heartbeatReady, perform: { ready in'
extra='''        .onChange(of: onDevicePairing.status, perform: { value in
            statusMessage = value
            if value.localizedCaseInsensitiveContains("fail") {
                isConnecting = false
                showError = true
            }
        })
        .onChange(of: onDevicePairing.isPairing, perform: { active in
            if !active && !manager.heartbeatReady { isConnecting = false }
        })
'''
s=replace_once(s,marker,extra+marker,'onboarding pairing status')
onboarding.write_text(s)

# Preserve the real metadata cards, hint sheets, transitions and queue progression.
# The removed Download tab's instruction becomes an import instruction on Music.
s=tutorial.read_text()
s=s.replace('    let downloadTabIndex: Int\n','')
s=s.replace('downloadHint','importHint')
s=s.replace('icon: "arrow.down.circle.fill"','icon: "square.and.arrow.down.fill"',1)
s=s.replace('title: "Download your first song"','title: "Import your first song"',1)
s=s.replace('body: "Open the Download tab, search for any song, and tap the download button next to it."','body: "Open the Music tab and import a song from Files or the share sheet."',1)
s=s.replace('tabIcon: "arrow.down.circle"','tabIcon: "music.note"',1)
s=s.replace('tabLabel: "Download tab"','tabLabel: "Music tab"',1)
s=s.replace('selectedTab = downloadTabIndex','selectedTab = 0')
tutorial.write_text(s)

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

grep -Fq 'Image("AppIconImage")' "$ONBOARDING"
grep -Fq 'struct StepRow: View' "$ONBOARDING"
grep -Fq 'private func metadataOptionCard(' "$TUTORIAL"
grep -Fq 'private func hintSheet(' "$TUTORIAL"
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
