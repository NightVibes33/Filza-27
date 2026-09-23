#!/usr/bin/env python3
from pathlib import Path

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)

content_path = Path("ByeTunes/MusicManager/ContentView.swift")
content = content_path.read_text()

content = replace_once(
    content,
'''    private var downloadTabIndex: Int {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let showRingtonesTab = (16...18).contains(major)
        return showRingtonesTab ? 2 : 1
    }
    
''',
    '',
    'remove download tab index'
)

content = replace_once(
    content,
'''            if !showSplash && hasCompletedOnboarding && !tutorialComplete {
                TutorialOverlayView(
                    isComplete: $tutorialComplete,
                    songs: $songs,
                    selectedTab: $selectedTab,
                    downloadTabIndex: downloadTabIndex
                )
                .zIndex(1)
            }

''',
    '',
    'remove downloader tutorial'
)

content = content.replace('            DownloadLiveActivityManager.shared.reconcileOrphanedActivitiesOnLaunch()\n', '')

content = replace_once(
    content,
'''        .onOpenURL { url in
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
''',
'''        .onOpenURL { url in
            if url.isFileURL {
                handleIncomingFile(url)
            }
        }
''',
    'remove download deep links'
)

content = replace_once(
    content,
'''    private var downloadTabIndex: Int { showRingtonesTab ? 2 : 1 }
    private var settingsTabIndex: Int { showRingtonesTab ? 3 : 2 }
''',
'''    private var settingsTabIndex: Int { showRingtonesTab ? 2 : 1 }
''',
    'floating tab indexes'
)

content = replace_once(
    content,
'''            TabBarButton(
                icon: "arrow.down.circle",
                title: "Download",
                isSelected: selectedTab == downloadTabIndex
            ) {
                selectedTab = downloadTabIndex
            }
''',
    '',
    'floating Download button'
)
content_path.write_text(content)

tabs_path = Path("ByeTunes/MusicManager/TabViews.swift")
tabs = tabs_path.read_text()
tabs = tabs.replace(
'''    private var downloadTabIndex: Int { showRingtonesTab ? 2 : 1 }
    private var settingsTabIndex: Int { showRingtonesTab ? 3 : 2 }
''',
'''    private var settingsTabIndex: Int { showRingtonesTab ? 2 : 1 }
''',
2
)
tabs = replace_once(
    tabs,
'''                } else if selectedTab == downloadTabIndex {
                    DownloadView(songs: $songs, status: $status)
''',
    '',
    'legacy Download view'
)
tabs = replace_once(
    tabs,
'''            DownloadView(songs: $songs, status: $status)
                .tabItem {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tag(downloadTabIndex)
''',
    '',
    'modern Download tab'
)
tabs_path.write_text(tabs)

settings_path = Path("ByeTunes/MusicManager/SettingsView.swift")
settings = settings_path.read_text()
settings = settings.replace('Text("DOWNLOADS")', 'Text("METADATA & LYRICS")', 1)
settings = settings.replace('Text("Metadata & Download Settings")', 'Text("Metadata & Lyrics")', 1)
settings = settings.replace('Text("Metadata source, downloader, quality, and saved downloads")', 'Text("Metadata sources, artwork, and lyrics")', 1)
settings = settings.replace('Image(systemName: "arrow.down.circle")', 'Image(systemName: "text.magnifyingglass")', 1)

anchor = 'private struct DownloaderSettingsScreen: View'
section = settings.find(anchor)
if section < 0:
    raise SystemExit('DownloaderSettingsScreen missing')

downloads = settings.find('                    Text("DOWNLOADS")\n', section)
if downloads < 0:
    raise SystemExit('download settings section missing')

close_marker = '                    }\n                    .frame(width: max(proxy.size.width - 40, 0), alignment: .leading)'
close = settings.find(close_marker, downloads)
if close < 0:
    raise SystemExit('download settings close marker missing')

settings = settings[:downloads] + '                    if false {\n' + settings[downloads:close] + '                    }\n\n' + settings[close:]
settings = settings.replace('.navigationTitle("Metadata & Downloads")', '.navigationTitle("Metadata & Lyrics")', 1)
settings = settings.replace('This has no effect on songs from the Download tab.', 'This only affects imported local files.', 1)
settings = settings.replace('when importing or downloading a song.', 'when importing a song.', 1)
settings_path.write_text(settings)

# Hard fail if the user-visible download tab survived any upstream drift.
for path in (content_path, tabs_path):
    text = path.read_text()
    if 'Label("Download", systemImage: "arrow.down.circle")' in text:
        raise SystemExit(f"Download tab survived in {path}")

print("ByeTunes embedded metadata/lyrics-only UI staged")
