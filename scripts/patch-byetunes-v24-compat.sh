#!/bin/bash
set -euo pipefail

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MUSIC="ByeTunes/MusicManager/MusicView.swift"
EDITOR="ByeTunes/MusicManager/ManualMetadataEditor.swift"
SEARCH_SHEET="ByeTunes/MusicManager/iTunesSearchSheet.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"

for file in "$SETTINGS" "$MUSIC" "$EDITOR" "$SEARCH_SHEET" "$DOWNLOAD"; do
    test -f "$file" || { echo "Missing $file" >&2; exit 1; }
done

python3 - "$SETTINGS" "$MUSIC" "$EDITOR" "$SEARCH_SHEET" "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys

settings = Path(sys.argv[1])
music = Path(sys.argv[2])
editor = Path(sys.argv[3])
search_sheet = Path(sys.argv[4])
download = Path(sys.argv[5])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Settings: restore the pre-v2.4 `all` persisted value and visible selectors.
# v2.4 still ships iTunes, Deezer, and Apple Music metadata engines, while its
# Download tab exposes Apple Music plus the combined iTunes+Deezer search.
# ---------------------------------------------------------------------------
ss = settings.read_text()
ss = replace_once(
    ss,
    '''private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {\n    case local\n    case itunes\n    case deezer\n    case apple\n''',
    '''private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {\n    case local\n    case itunes\n    case deezer\n    case apple\n    case all\n''',
    "metadata All Sources enum",
)
ss = replace_once(
    ss,
    '''        case .deezer: return "Deezer API"\n        case .apple: return "Apple Music"\n''',
    '''        case .deezer: return "Deezer API"\n        case .apple: return "Apple Music"\n        case .all: return "All Sources"\n''',
    "metadata All Sources label",
)
ss = replace_once(
    ss,
    '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {\n    case appleMusic\n    case spotify\n    case tidal\n    case metadata\n\n    static var allCases: [DownloadSearchProviderOption] {\n        [.appleMusic, .metadata]\n    }\n''',
    '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {\n    case appleMusic\n    case spotify\n    case tidal\n    case metadata\n    case all\n\n    static var allCases: [DownloadSearchProviderOption] {\n        [.appleMusic, .metadata, .all]\n    }\n''',
    "download All Sources enum",
)
ss = replace_once(
    ss,
    '''        case .tidal: return "Tidal"\n        case .metadata: return "iTunes + Deezer"\n''',
    '''        case .tidal: return "Tidal"\n        case .metadata: return "iTunes + Deezer"\n        case .all: return "All Sources"\n''',
    "download All Sources label",
)
ss = ss.replace(
    "Choose which service the Download tab searches for songs: Apple Music search results, or a match by metadata across all supported download sources.",
    "Choose Apple Music, iTunes + Deezer metadata, or All Sources to merge both result sets.",
)
settings.write_text(ss)


# ---------------------------------------------------------------------------
# Music import: v2.4 reads the legacy `metadataSource` key but omitted `all`
# from its enrichment chain. That turns an old working preference into a silent
# no-op. Restore the old multi-provider behavior using the engines v2.4 ships.
# ---------------------------------------------------------------------------
ms = music.read_text()
old_import_enrichment = '''            if metadataSource == "apple" && autofetch {\n                song = await SongMetadata.enrichWithAppleMusicMetadata(song)\n            } else if useiTunes && autofetch {\n                song = await SongMetadata.enrichWithiTunesMetadata(song)\n            } else if metadataSource == "deezer" && autofetch {\n                song = await SongMetadata.enrichWithDeezerMetadata(song)\n            } else if metadataSource == "local" && autofetch {\n                if UserDefaults.standard.bool(forKey: "appleRichMetadata") {\n                    song = await SongMetadata.matchAppleMusicMetadata(song)\n                }\n            }\n'''
new_import_enrichment = '''            if metadataSource == "all" && autofetch {\n                Logger.shared.log("[MusicView] All Sources metadata pass: iTunes + Deezer + Apple Music")\n                song = await SongMetadata.enrichWithiTunesMetadata(song)\n                song = await SongMetadata.enrichWithDeezerMetadata(song)\n                song = await SongMetadata.enrichWithAppleMusicMetadata(song)\n            } else if metadataSource == "apple" && autofetch {\n                song = await SongMetadata.enrichWithAppleMusicMetadata(song)\n            } else if useiTunes && autofetch {\n                song = await SongMetadata.enrichWithiTunesMetadata(song)\n            } else if metadataSource == "deezer" && autofetch {\n                song = await SongMetadata.enrichWithDeezerMetadata(song)\n            } else if metadataSource == "local" && autofetch {\n                if UserDefaults.standard.bool(forKey: "appleRichMetadata") {\n                    song = await SongMetadata.matchAppleMusicMetadata(song)\n                }\n            }\n'''
ms = replace_once(ms, old_import_enrichment, new_import_enrichment, "MusicView all-source import enrichment")
music.write_text(ms)


# ---------------------------------------------------------------------------
# Manual editor: make the persisted `all` state honest and usable again.
# ---------------------------------------------------------------------------
es = editor.read_text()
old_display = 'Text(metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized))'
new_display = 'Text(metadataSource == "all" ? "All Sources" : (metadataSource == "local" ? "iTunes" : (metadataSource == "apple" ? "Apple Music" : metadataSource.capitalized)))'
count = es.count(old_display)
if new_display not in es:
    if count != 1:
        raise SystemExit(f"ManualMetadataEditor source label: expected 1 anchor, found {count}")
    es = es.replace(old_display, new_display, 1)
old_footer = 'Text("Search \\(metadataSource == \"local\" ? \"iTunes\" : (metadataSource == \"apple\" ? \"Apple Music\" : metadataSource.capitalized)) to auto-fill metadata fields")'
new_footer = 'Text("Search \\(metadataSource == \"all\" ? \"all available sources\" : (metadataSource == \"local\" ? \"iTunes\" : (metadataSource == \"apple\" ? \"Apple Music\" : metadataSource.capitalized))) to auto-fill metadata fields")'
es = replace_once(es, old_footer, new_footer, "ManualMetadataEditor source footer")
editor.write_text(es)


# ---------------------------------------------------------------------------
# Metadata search sheet: old `all` used to keep the per-provider menu visible.
# v2.4 retained all three engines but only treated `local` as menu-capable.
# ---------------------------------------------------------------------------
isrc = search_sheet.read_text()
old_local_gate = '            if metadataSource == "local" {\n'
new_all_gate = '            if metadataSource == "local" || metadataSource == "all" {\n'
if new_all_gate not in isrc:
    count = isrc.count(old_local_gate)
    if count != 2:
        raise SystemExit(f"iTunesSearchSheet all-source gates: expected 2 anchors, found {count}")
    isrc = isrc.replace(old_local_gate, new_all_gate)
search_sheet.write_text(isrc)


# ---------------------------------------------------------------------------
# Download search: v2.4 removed SearchProvider.all. Keep the v2.4 enum intact
# (avoids disturbing every provider switch) and implement `all` as a view-level
# compatibility mode that merges Apple Music with the iTunes+Deezer metadata
# provider. IDs are String for all public result types, so deterministic de-dupe
# by id is safe.
# ---------------------------------------------------------------------------
ds = download.read_text()
search_func_anchor = '''    func search(query: String, provider: DownloadView.SearchProvider) async {\n'''
all_search_method = '''    private func mergeResultsByID<T: Identifiable>(_ first: [T], _ second: [T]) -> [T] where T.ID: Hashable {\n        var seen = Set<T.ID>()\n        return (first + second).filter { seen.insert($0.id).inserted }\n    }\n\n    func searchAllSources(query: String) async {\n        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !trimmed.isEmpty else {\n            artistResults = []\n            songResults = []\n            albumResults = []\n            playlistResults = []\n            errorText = nil\n            return\n        }\n\n        await search(query: trimmed, provider: .appleMusic)\n        let appleArtists = artistResults\n        let appleSongs = songResults\n        let appleAlbums = albumResults\n        let applePlaylists = playlistResults\n        let appleError = errorText\n\n        await search(query: trimmed, provider: .metadata)\n        let metadataArtists = artistResults\n        let metadataSongs = songResults\n        let metadataAlbums = albumResults\n        let metadataPlaylists = playlistResults\n        let metadataError = errorText\n\n        artistResults = mergeResultsByID(appleArtists, metadataArtists)\n        songResults = mergeResultsByID(appleSongs, metadataSongs)\n        albumResults = mergeResultsByID(appleAlbums, metadataAlbums)\n        playlistResults = mergeResultsByID(applePlaylists, metadataPlaylists)\n        canLoadMoreSongs = false\n        canLoadMoreAlbums = false\n        canLoadMorePlaylists = false\n        isLoadingMoreSongs = false\n        isLoadingMoreAlbums = false\n        isLoadingMorePlaylists = false\n\n        if artistResults.isEmpty && songResults.isEmpty && albumResults.isEmpty && playlistResults.isEmpty {\n            errorText = metadataError ?? appleError\n        } else {\n            errorText = nil\n        }\n        Logger.shared.log("[DownloadView] All Sources search merged Apple Music + iTunes/Deezer: songs=\\(songResults.count) albums=\\(albumResults.count)")\n    }\n\n'''
if "func searchAllSources(query: String) async" not in ds:
    if ds.count(search_func_anchor) != 1:
        raise SystemExit("DownloadView search function anchor not found uniquely")
    ds = ds.replace(search_func_anchor, all_search_method + search_func_anchor, 1)

search_provider_block = '''    private var searchProvider: SearchProvider {\n        get {\n            guard let provider = SearchProvider(rawValue: searchProviderRaw) else {\n                return .appleMusic\n            }\n            return provider == .tidal ? .appleMusic : provider\n'''
if search_provider_block not in ds and "private var isAllSourcesSearch" not in ds:
    raise SystemExit("DownloadView searchProvider getter anchor not found")

# Insert compatibility helpers immediately before the existing searchProvider.
helpers = '''    private var isAllSourcesSearch: Bool {\n        searchProviderRaw == "all"\n    }\n\n    private var searchPlaceholderText: String {\n        isAllSourcesSearch ? "Search all available sources" : searchProvider.searchPlaceholder\n    }\n\n    private var emptyStateSubtitleText: String {\n        isAllSourcesSearch ? "Search Apple Music plus iTunes + Deezer" : searchProvider.emptyStateSubtitle\n    }\n\n    private func runSearch(_ value: String) {\n        Task {\n            if isAllSourcesSearch {\n                await vm.searchAllSources(query: value)\n            } else {\n                await vm.search(query: value, provider: searchProvider)\n            }\n        }\n    }\n\n'''
if "private var isAllSourcesSearch" not in ds:
    ds = ds.replace("    private var searchProvider: SearchProvider {\n", helpers + "    private var searchProvider: SearchProvider {\n", 1)

# Make visible text match the raw All Sources mode.
ds = ds.replace("TextField(searchProvider.searchPlaceholder, text: $query)", "TextField(searchPlaceholderText, text: $query)")
ds = ds.replace("Text(searchProvider.emptyStateSubtitle)", "Text(emptyStateSubtitleText)")

# Route all three search entry points through the compatibility dispatcher.
ds = ds.replace("Task { await vm.search(query: query, provider: searchProvider) }", "runSearch(query)")
ds = ds.replace('''                Task {\n                    await vm.search(query: link, provider: searchProvider)\n                }\n''', '''                runSearch(link)\n''')
old_change = '''            let provider = SearchProvider(rawValue: newValue) ?? .appleMusic\n            Task { await vm.search(query: query, provider: provider) }\n'''
new_change = '''            runSearch(query)\n'''
if old_change in ds:
    ds = ds.replace(old_change, new_change, 1)
elif new_change not in ds:
    raise SystemExit("DownloadView provider-change search anchor not found")

download.write_text(ds)
PY

# Fail closed if a future ByeTunes update removes the compatibility anchors.
grep -Fq 'case all' "$SETTINGS"
grep -Fq 'case .all: return "All Sources"' "$SETTINGS"
grep -Fq 'metadataSource == "all" && autofetch' "$MUSIC"
grep -Fq 'All Sources metadata pass: iTunes + Deezer + Apple Music' "$MUSIC"
grep -Fq 'metadataSource == "local" || metadataSource == "all"' "$SEARCH_SHEET"
grep -Fq 'func searchAllSources(query: String) async' "$DOWNLOAD"
grep -Fq 'searchProviderRaw == "all"' "$DOWNLOAD"
grep -Fq 'Search all available sources' "$DOWNLOAD"

echo "ByeTunes v2.4 compatibility patch applied"
