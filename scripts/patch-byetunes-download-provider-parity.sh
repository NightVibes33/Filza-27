#!/usr/bin/env bash
set -euo pipefail

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"
for path in "$SETTINGS" "$DOWNLOAD"; do test -f "$path"; done

python3 - "$SETTINGS" "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys
settings, download = map(Path, sys.argv[1:3])

def replace_once(text, old, new, label):
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)

def function_range(text, signature):
    start = text.find(signature)
    if start < 0: raise SystemExit(f"function not found: {signature}")
    brace = text.find("{", start)
    if brace < 0: raise SystemExit(f"opening brace not found: {signature}")
    depth = 0; in_string = False; escape = False
    for i in range(brace, len(text)):
        ch = text[i]
        if in_string:
            if escape: escape = False
            elif ch == "\\": escape = True
            elif ch == '"': in_string = False
        else:
            if ch == '"': in_string = True
            elif ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: return start, i + 1
    raise SystemExit(f"closing brace not found: {signature}")

def replace_in_function(text, signature, old, new, label):
    start, end = function_range(text, signature)
    block = text[start:end]
    if new in block and old not in block: return text
    count = block.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one function-local anchor, found {count}")
    return text[:start] + block.replace(old, new, 1) + text[end:]

ss = settings.read_text()
ss = replace_once(ss, '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
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
''', '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case appleMusic
    case spotify
    case tidal
    case metadata
    case youtube
    case all

    static var allCases: [DownloadSearchProviderOption] {
        [.appleMusic, .tidal, .metadata, .youtube, .all]
    }

    var id: String { rawValue }

    var description: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .tidal: return "Tidal"
        case .metadata: return "iTunes + Deezer"
        case .youtube: return "YouTube"
        case .all: return "All Sources"
        }
    }
}
''', "legacy download settings provider list")
settings.write_text(ss)

dv = download.read_text()
dv = replace_once(dv, '''    enum SearchProvider: String, CaseIterable, Identifiable {
        case appleMusic
        case spotify
        case tidal
        case metadata

        static var allCases: [SearchProvider] {
            [.appleMusic, .metadata]
        }
''', '''    enum SearchProvider: String, CaseIterable, Identifiable {
        case appleMusic
        case spotify
        case tidal
        case metadata
        case youtube

        static var allCases: [SearchProvider] {
            [.appleMusic, .tidal, .metadata, .youtube]
        }
''', "DownloadView SearchProvider cases")
dv = replace_once(dv, '            case .metadata: return "iTunes + Deezer"\n', '            case .metadata: return "iTunes + Deezer"\n            case .youtube: return "YouTube"\n', "YouTube title")
dv = replace_once(dv, '            case .metadata: return "Search iTunes and Deezer"\n', '            case .metadata: return "Search iTunes and Deezer"\n            case .youtube: return "Search YouTube for unreleased and custom songs"\n', "YouTube placeholder")
dv = replace_once(dv, '            case .metadata: return "Search iTunes and Deezer and tap download"\n', '            case .metadata: return "Search iTunes and Deezer and tap download"\n            case .youtube: return "Search YouTube for unreleased tracks and custom songs"\n', "YouTube empty state")
dv = replace_once(dv, '            return provider == .tidal ? .appleMusic : provider\n', '            return provider\n', "Tidal remap")
dv = replace_once(dv, '            if searchProviderRaw == SearchProvider.tidal.rawValue || searchProviderRaw == SearchProvider.spotify.rawValue {\n                searchProviderRaw = SearchProvider.appleMusic.rawValue\n            }\n', '            if searchProviderRaw == SearchProvider.spotify.rawValue {\n                searchProviderRaw = SearchProvider.appleMusic.rawValue\n            }\n', "Tidal reset")

# The first metadata-compat patch introduces a raw `all` compatibility route.
# Close every remaining UI/search call-site that would otherwise decode `all`
# as nil and silently fall back to Apple Music.
dv = replace_once(dv, '''    private var configuredSearchPlaceholder: String {
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
''', '''    private var configuredSearchPlaceholder: String {
        if searchProviderRaw == "all" {
            return "Search all available sources"
        }
        return searchProvider.searchPlaceholder
    }

    private var configuredEmptyStateSubtitle: String {
        if searchProviderRaw == "all" {
            return "Search all sources and tap download"
        }
        return searchProvider.emptyStateSubtitle
    }

    private func performConfiguredSearch() {
        performConfiguredSearch(query)
    }

    private func performConfiguredSearch(_ value: String) {
        Task {
            if searchProviderRaw == "all" {
                await vm.searchAllLegacySourcesCompat(query: value)
            } else {
                let provider = SearchProvider(rawValue: searchProviderRaw) ?? .appleMusic
                await vm.search(query: value, provider: provider)
            }
        }
    }
''', "All provider UI/search helpers")

dv = replace_once(dv, '                            Text(searchProvider.emptyStateSubtitle)\n', '                            Text(configuredEmptyStateSubtitle)\n', "All empty-state subtitle")

dv = replace_once(dv, '''                Task {
                    await vm.search(query: link, provider: searchProvider)
                }
''', '''                performConfiguredSearch(link)
''', "IncomingMusicLink All routing")

dv = replace_once(dv, '''            if newValue == "all" {
                Task { await vm.searchAllSourcesCompat(query: query) }
            } else {
                let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
                Task { await vm.search(query: query, provider: provider) }
            }
''', '''            if newValue == "all" {
                Task { await vm.searchAllLegacySourcesCompat(query: query) }
            } else {
                let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
                Task { await vm.search(query: query, provider: provider) }
            }
''', "provider-change lifecycle")

# Old YouTube pseudo-albums first reopened their grouped cached YouTube tracks;
# if that cache was unavailable they fell back to the same metadata album query
# used by the old implementation. Restore that functional behavior exactly.
dv = replace_in_function(dv, "    func loadTracks(for album: DownloadAlbum) async -> [DownloadTrack] {", '        case .metadata:\n', '''        case .youtube:
            let cached = ByeTunesLegacyYouTubeAlbumCache.tracks(for: album.id)
            if !cached.isEmpty {
                return cached
            }
            let query = "\(album.artistLine) \(album.name)"
            let batch = await fetchMetadataSearchTracks(query: query, limit: 50, deezerIndex: 0, includeITunes: true)
            let matchingTracks = batch.tracks.filter { track in
                DownloadSupport.normalizedSearchValue(track.albumName) == DownloadSupport.normalizedSearchValue(album.name) &&
                matchesArtistLine(track.artistLine, artistName: album.artistLine)
            }
            return matchingTracks.isEmpty ? batch.tracks : matchingTracks
        case .metadata:
''', "YouTube album cache/fallback")
dv = replace_in_function(dv, "    func loadTracks(forPlaylist playlist: DownloadAlbum) async -> [DownloadTrack] {", '        case .tidal, .metadata:\n            return []\n', '        case .tidal, .metadata, .youtube:\n            return []\n', "YouTube playlist")
dv = replace_in_function(dv, "    func search(query: String, provider: DownloadView.SearchProvider) async {", '        case .metadata:\n', '        case .youtube:\n            await searchYouTubeLegacyCompat(query: trimmed)\n\n        case .metadata:\n', "YouTube search")
dv = replace_in_function(dv, "    func loadMoreSongs() async {", '        case .metadata:\n', '        case .youtube:\n            canLoadMoreSongs = false\n        case .metadata:\n', "YouTube song pagination")
dv = replace_in_function(dv, "    func loadMoreAlbums() async {", '        case .metadata:\n', '        case .youtube:\n            canLoadMoreAlbums = false\n        case .metadata:\n', "YouTube album pagination")
dv = replace_in_function(dv, "    func loadMorePlaylists() async {", '        case .tidal, .metadata:\n            canLoadMorePlaylists = false\n', '        case .tidal, .metadata, .youtube:\n            canLoadMorePlaylists = false\n', "YouTube playlist pagination")
dv = replace_in_function(dv, "    func loadArtistProfile(for artist: DownloadArtist) async -> DownloadArtistProfile {", '        case .tidal, .metadata, .spotify:\n            return await buildMetadataArtistProfile(for: artist.name)\n', '        case .tidal, .metadata, .spotify, .youtube:\n            return await buildMetadataArtistProfile(for: artist.name)\n', "YouTube artist profile")

dv = replace_once(dv, '''        switch track.provider {
        case .appleMusic, .spotify, .metadata, .tidal:
            resolved = await resolveITunesPreviewURL(for: track)
        }
''', '''        switch track.provider {
        case .appleMusic, .spotify, .metadata, .tidal:
            resolved = await resolveITunesPreviewURL(for: track)
        case .youtube:
            if let videoID = MetadataProvider.extractYouTubeVideoID(from: track.sourceURL) {
                resolved = await MetadataProvider.resolveYouTubeAudioStreamURLCompat(videoID: videoID)
            } else {
                resolved = nil
            }
        }
''', "YouTube preview resolver")

download.write_text(dv)
PY

grep -Fq 'case youtube' "$SETTINGS"
grep -Fq '[.appleMusic, .tidal, .metadata, .youtube, .all]' "$SETTINGS"
grep -Fq 'case youtube' "$DOWNLOAD"
grep -Fq 'Search YouTube for unreleased and custom songs' "$DOWNLOAD"
grep -Fq 'configuredEmptyStateSubtitle' "$DOWNLOAD"
grep -Fq 'performConfiguredSearch(link)' "$DOWNLOAD"
grep -Fq 'searchAllLegacySourcesCompat' "$DOWNLOAD"
grep -Fq 'searchYouTubeLegacyCompat' "$DOWNLOAD"
grep -Fq 'ByeTunesLegacyYouTubeAlbumCache.tracks(for: album.id)' "$DOWNLOAD"
grep -Fq 'resolveYouTubeAudioStreamURLCompat' "$DOWNLOAD"
grep -Fq 'case .tidal, .metadata, .spotify, .youtube:' "$DOWNLOAD"
! grep -Fq 'Search Apple Music, iTunes, and Deezer' "$DOWNLOAD"
! grep -Fq 'return provider == .tidal ? .appleMusic : provider' "$DOWNLOAD"
echo 'Applied pre-v2.4 ByeTunes download-provider parity'
