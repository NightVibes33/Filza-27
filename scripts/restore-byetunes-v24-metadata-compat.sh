#!/bin/bash
set -euo pipefail

MUSIC="ByeTunes/MusicManager/MusicView.swift"
SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MANUAL="ByeTunes/MusicManager/ManualMetadataEditor.swift"
SEARCH_SHEET="ByeTunes/MusicManager/iTunesSearchSheet.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"
BACKGROUND="ByeTunes/MusicManager/BackgroundMetadataFetchManager.swift"

for path in "$MUSIC" "$SETTINGS" "$MANUAL" "$SEARCH_SHEET" "$DOWNLOAD" "$BACKGROUND"; do
    test -f "$path"
done

python3 - "$MUSIC" "$SETTINGS" "$MANUAL" "$SEARCH_SHEET" "$DOWNLOAD" "$BACKGROUND" <<'PY'
from pathlib import Path
import sys

music = Path(sys.argv[1])
settings = Path(sys.argv[2])
manual = Path(sys.argv[3])
search_sheet = Path(sys.argv[4])
download = Path(sys.argv[5])
background = Path(sys.argv[6])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old in text:
        return text.replace(old, new, 1)
    if new in text:
        return text
    raise SystemExit(f"{label} anchor not found")


# ---------------------------------------------------------------------------
# Music import: v2.4 collapsed metadataSource to one source and silently did
# nothing for the legacy persisted value "all". Restore the pre-v2.4 source
# list contract, including YouTube metadata, while retaining v2.4 import logic.
# ---------------------------------------------------------------------------
ms = music.read_text()
ms = ms.replace(
    '        let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"\n        let useiTunes = (metadataSource == "itunes")\n',
    '        MetadataProviderSettings.migrateIfNeeded()\n',
    1,
)
old_music_enrichment = '''            if metadataSource == "apple" && autofetch {
                song = await SongMetadata.enrichWithAppleMusicMetadata(song)
            } else if useiTunes && autofetch {
                song = await SongMetadata.enrichWithiTunesMetadata(song)
            } else if metadataSource == "deezer" && autofetch {
                song = await SongMetadata.enrichWithDeezerMetadata(song)
            } else if metadataSource == "local" && autofetch {
                if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                    song = await SongMetadata.matchAppleMusicMetadata(song)
                }
            }
'''
new_music_enrichment = '''            if autofetch {
                let sources = MetadataProviderSettings.selectedSources()
                Logger.shared.log("[MusicView] Filza embed metadata compatibility sources=\\(sources.map(\\.rawValue).joined(separator: ","))")
                for source in sources {
                    switch source {
                    case .local:
                        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                            song = await SongMetadata.matchAppleMusicMetadata(song)
                        }
                    case .youtube:
                        song = await MetadataProvider.enrichSongMetadata(song)
                    case .itunes:
                        song = await SongMetadata.enrichWithiTunesMetadata(song)
                    case .deezer:
                        song = await SongMetadata.enrichWithDeezerMetadata(song)
                    case .apple:
                        song = await SongMetadata.enrichWithAppleMusicMetadata(song)
                    }
                }
            }
'''
ms = replace_once(ms, old_music_enrichment, new_music_enrichment, "MusicView multi-source enrichment")
music.write_text(ms)


# ---------------------------------------------------------------------------
# Background metadata: downloaded songs must obey the same All/YouTube source
# selection as foreground imports.
# ---------------------------------------------------------------------------
bg = background.read_text()
bg = bg.replace(
    '        let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"\n',
    '        MetadataProviderSettings.migrateIfNeeded()\n',
    1,
)
old_bg_enrichment = '''        if metadataSource == "apple" && autofetch {
            song = await SongMetadata.enrichWithAppleMusicMetadata(song)
        } else if metadataSource == "itunes" && autofetch {
            song = await SongMetadata.enrichWithiTunesMetadata(song)
        } else if metadataSource == "deezer" && autofetch {
            song = await SongMetadata.enrichWithDeezerMetadata(song)
        } else if metadataSource == "local" && autofetch {
            if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                song = await SongMetadata.matchAppleMusicMetadata(song)
            }
        }
'''
new_bg_enrichment = '''        if autofetch {
            for source in MetadataProviderSettings.selectedSources() {
                switch source {
                case .local:
                    if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                        song = await SongMetadata.matchAppleMusicMetadata(song)
                    }
                case .youtube:
                    song = await MetadataProvider.enrichSongMetadata(song)
                case .itunes:
                    song = await SongMetadata.enrichWithiTunesMetadata(song)
                case .deezer:
                    song = await SongMetadata.enrichWithDeezerMetadata(song)
                case .apple:
                    song = await SongMetadata.enrichWithAppleMusicMetadata(song)
                }
            }
        }
'''
bg = replace_once(bg, old_bg_enrichment, new_bg_enrichment, "background multi-source enrichment")
background.write_text(bg)


# ---------------------------------------------------------------------------
# Settings: put YouTube and All Sources back in Metadata, and All Sources back
# in Download search. Persist the old multi-source contract so an existing
# metadataSource=all installation immediately works again after upgrading.
# ---------------------------------------------------------------------------
ss = settings.read_text()
ss = ss.replace(
    "Local Files uses only what's already tagged on the file; iTunes, Deezer, and Apple Music look up matches online to fill in and correct title, artist, album, and artwork.",
    "Local Files uses only what's already tagged on the file; YouTube, iTunes, Deezer, and Apple Music can look up matches online. All Sources tries every available metadata provider.",
)
ss = ss.replace(
    'if metadataSource == "itunes" || metadataSource == "deezer" || metadataSource == "apple" {',
    'if metadataSource == "youtube" || metadataSource == "itunes" || metadataSource == "deezer" || metadataSource == "apple" || metadataSource == "all" {',
    1,
)
ss = ss.replace(
    'if metadataSource == "itunes" {',
    'if metadataSource == "itunes" || metadataSource == "all" {',
    1,
)

helper_anchor = '''    var body: some View {
'''
helper = '''    private func persistMetadataSelection(_ value: String) {
        if value == "all" {
            MetadataProviderSettings.saveSources(MetadataProviderSettings.defaultSources)
        } else if value == "youtube" {
            MetadataProviderSettings.saveSources([.local, .youtube])
        } else if let provider = MetadataProviderID(rawValue: value) {
            MetadataProviderSettings.saveSources([provider])
        } else {
            MetadataProviderSettings.saveSources([.local])
        }
    }

    var body: some View {
'''
if "private func persistMetadataSelection" not in ss:
    idx = ss.find("private struct DownloaderSettingsScreen: View")
    if idx < 0:
        raise SystemExit("DownloaderSettingsScreen not found")
    body_idx = ss.find(helper_anchor, idx)
    if body_idx < 0:
        raise SystemExit("DownloaderSettingsScreen body anchor not found")
    ss = ss[:body_idx] + helper + ss[body_idx + len(helper_anchor):]

old_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
        }
'''
new_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metadataSource) { newValue in
            persistMetadataSelection(newValue)
        }
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
            MetadataProviderSettings.migrateIfNeeded()
            persistMetadataSelection(metadataSource)
        }
'''
ss = replace_once(ss, old_modifiers, new_modifiers, "DownloaderSettings metadata persistence")

old_metadata_enum = '''private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case local
    case itunes
    case deezer
    case apple

    var id: String { rawValue }

    var description: String {
        switch self {
        case .local: return "Local Files"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        }
    }
}
'''
new_metadata_enum = '''private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case local
    case youtube
    case itunes
    case deezer
    case apple
    case all

    var id: String { rawValue }

    var description: String {
        switch self {
        case .local: return "Local Files"
        case .youtube: return "YouTube"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        case .all: return "All Sources"
        }
    }
}
'''
ss = replace_once(ss, old_metadata_enum, new_metadata_enum, "MetadataSourceOption All/YouTube")

old_download_enum = '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case appleMusic
    case spotify
    case tidal
    case metadata

    static var allCases: [DownloadSearchProviderOption] {
        [.appleMusic, .metadata]
    }

    var id: String { rawValue }

    var description: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .tidal: return "Tidal"
        case .metadata: return "iTunes + Deezer"
        }
    }
}
'''
new_download_enum = '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case appleMusic
    case spotify
    case tidal
    case metadata
    case all

    static var allCases: [DownloadSearchProviderOption] {
        [.appleMusic, .metadata, .all]
    }

    var id: String { rawValue }

    var description: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .tidal: return "Tidal"
        case .metadata: return "iTunes + Deezer"
        case .all: return "All Sources"
        }
    }
}
'''
ss = replace_once(ss, old_download_enum, new_download_enum, "DownloadSearchProviderOption All")
settings.write_text(ss)


# ---------------------------------------------------------------------------
# Manual metadata editor: make an old saved value of "all" explicit instead
# of presenting a misleading source label.
# ---------------------------------------------------------------------------
me = manual.read_text()
me = me.replace(
    'Text(metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized))',
    'Text(metadataSource == "all" ? "All Sources" : (metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized)))',
)
me = me.replace(
    'Text("Search \\(metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized)) to auto-fill metadata fields")',
    'Text("Search \\(metadataSource == "all" ? "all available sources" : (metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized))) to auto-fill metadata fields")',
)
manual.write_text(me)


# ---------------------------------------------------------------------------
# Manual metadata search sheet: restore the removed YouTube picker path and
# make All Sources expose iTunes / Deezer / Apple Music / YouTube again.
# ---------------------------------------------------------------------------
its = search_sheet.read_text()
its = replace_once(
    its,
    '    @State private var appleResults: [AppleMusicAPI.AppleMusicSong] = []\n',
    '    @State private var appleResults: [AppleMusicAPI.AppleMusicSong] = []\n    @State private var youtubeResults: [YouTubeMetadataCandidate] = []\n',
    "YouTube search result state",
)
its = its.replace('if metadataSource == "local" {', 'if metadataSource == "local" || metadataSource == "all" {')
its = replace_once(
    its,
    '                            Button("Apple Music") { activeSource = "apple" }\n',
    '                            Button("Apple Music") { activeSource = "apple" }\n                            Button("YouTube") { activeSource = "youtube" }\n',
    "manual metadata YouTube menu",
)
its = its.replace(
    'Text(activeSource == "apple" ? "Apple Music" : activeSource.capitalized)',
    'Text(activeSource == "youtube" ? "YouTube" : (activeSource == "apple" ? "Apple Music" : activeSource.capitalized))',
)
its = its.replace(
    'TextField("Search \\(activeSource == "deezer" ? "Deezer" : (activeSource == "apple" ? "Apple Music" : "iTunes (\\(UserDefaults.standard.string(forKey: "storeRegion") ?? "US"))"))...", text: $searchQuery)',
    'TextField("Search \\(activeSource == "youtube" ? "YouTube" : (activeSource == "deezer" ? "Deezer" : (activeSource == "apple" ? "Apple Music" : "iTunes (\\(UserDefaults.standard.string(forKey: "storeRegion") ?? "US"))")))...", text: $searchQuery)',
)
its = its.replace(
    'Text("Searching \\(activeSource == "deezer" ? "Deezer" : (activeSource == "apple" ? "Apple Music" : "iTunes (\\(UserDefaults.standard.string(forKey: "storeRegion") ?? "US"))"))...")',
    'Text("Searching \\(activeSource == "youtube" ? "YouTube" : (activeSource == "deezer" ? "Deezer" : (activeSource == "apple" ? "Apple Music" : "iTunes (\\(UserDefaults.standard.string(forKey: "storeRegion") ?? "US"))")))...")',
)
its = its.replace(
    'else if (activeSource == "deezer" ? deezerResults.isEmpty : (activeSource == "apple" ? appleResults.isEmpty : itunesResults.isEmpty)) {',
    'else if (activeSource == "youtube" ? youtubeResults.isEmpty : (activeSource == "deezer" ? deezerResults.isEmpty : (activeSource == "apple" ? appleResults.isEmpty : itunesResults.isEmpty))) {',
    1,
)
old_results_fallthrough = '''                            } else {
                                ForEach(Array(itunesResults.enumerated()), id: \.element.trackId) { index, match in
'''
new_results_fallthrough = '''                            } else if activeSource == "youtube" {
                                ForEach(Array(youtubeResults.enumerated()), id: \.element.videoID) { index, match in
                                    VStack(spacing: 0) {
                                        Button {
                                            applyYouTubeMatch(match)
                                        } label: {
                                            ByeTunesYouTubeMetadataRow(match: match)
                                        }
                                        .buttonStyle(PlainButtonStyle())

                                        if index < youtubeResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                            } else {
                                ForEach(Array(itunesResults.enumerated()), id: \.element.trackId) { index, match in
'''
its = replace_once(its, old_results_fallthrough, new_results_fallthrough, "manual metadata YouTube results")
its = its.replace(
    '            appleResults = []\n            performSearch()\n',
    '            appleResults = []\n            youtubeResults = []\n            performSearch()\n',
    1,
)
old_search_branch = '''            } else if activeSource == "apple" {
                 let results = await AppleMusicAPI.shared.searchSongs(query: searchQuery, limit: 10)
                 await MainActor.run {
                     self.appleResults = results
                     self.isLoading = false
                 }
            } else {
'''
new_search_branch = '''            } else if activeSource == "apple" {
                 let results = await AppleMusicAPI.shared.searchSongs(query: searchQuery, limit: 10)
                 await MainActor.run {
                     self.appleResults = results
                     self.isLoading = false
                 }
            } else if activeSource == "youtube" {
                 let results = await MetadataProvider.searchYouTubeForMetadata(query: searchQuery, limit: 10)
                 await MainActor.run {
                     self.youtubeResults = results
                     self.isLoading = false
                 }
            } else {
'''
its = replace_once(its, old_search_branch, new_search_branch, "manual metadata YouTube search")

apply_anchor = '''    private func applyAppleMatch(_ match: AppleMusicAPI.AppleMusicSong) {
        isLoading = true
        Task {
            let updatedSong = await SongMetadata.applyAppleMusicMatch(match, to: song)
            
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
'''
apply_youtube = apply_anchor + '''
    private func applyYouTubeMatch(_ match: YouTubeMetadataCandidate) {
        isLoading = true
        Task {
            let updatedSong = await MetadataProvider.applyYouTubeMatch(match, to: song)
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
'''
its = replace_once(its, apply_anchor, apply_youtube, "manual metadata YouTube apply")
search_sheet.write_text(its)


# ---------------------------------------------------------------------------
# Download search: do not add a new nested enum case (which would require
# changing every v2.4 switch). A raw setting of "all" instead calls a compat
# merger that runs v2.4 Apple Music and iTunes+Deezer searches and de-duplicates
# their results.
# ---------------------------------------------------------------------------
dv = download.read_text()
search_helper_anchor = '''    var body: some View {
'''
search_helper = '''    private var configuredSearchPlaceholder: String {
        if searchProviderRaw == "all" {
            return "Search Apple Music, iTunes, and Deezer"
        }
        return searchProvider.searchPlaceholder
    }

    private func performConfiguredSearch() {
        Task {
            if searchProviderRaw == "all" {
                await vm.searchAllSourcesCompat(query: query)
            } else {
                await vm.search(query: query, provider: searchProvider)
            }
        }
    }

    var body: some View {
'''
if "private func performConfiguredSearch" not in dv:
    body_idx = dv.find(search_helper_anchor)
    if body_idx < 0:
        raise SystemExit("DownloadView body anchor not found")
    dv = dv[:body_idx] + search_helper + dv[body_idx + len(search_helper_anchor):]

dv = dv.replace('TextField(searchProvider.searchPlaceholder, text: $query)', 'TextField(configuredSearchPlaceholder, text: $query)', 1)
dv = dv.replace('Task { await vm.search(query: query, provider: searchProvider) }', 'performConfiguredSearch()', 2)
old_provider_change = '''            let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
            Task { await vm.search(query: query, provider: provider) }
'''
new_provider_change = '''            if newValue == "all" {
                Task { await vm.searchAllSourcesCompat(query: query) }
            } else {
                let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
                Task { await vm.search(query: query, provider: provider) }
            }
'''
dv = replace_once(dv, old_provider_change, new_provider_change, "DownloadView All source search")
download.write_text(dv)
PY

grep -Fq 'Filza embed metadata compatibility sources=' "$MUSIC"
grep -Fq 'case .youtube:' "$MUSIC"
grep -Fq 'case youtube' "$SETTINGS"
grep -Fq 'case all' "$SETTINGS"
grep -Fq 'All Sources' "$SETTINGS"
grep -Fq 'Button("YouTube")' "$SEARCH_SHEET"
grep -Fq 'searchYouTubeForMetadata' "$SEARCH_SHEET"
grep -Fq 'searchAllSourcesCompat' "$DOWNLOAD"
grep -Fq 'case .youtube:' "$BACKGROUND"
