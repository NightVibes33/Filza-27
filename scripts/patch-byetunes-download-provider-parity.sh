#!/usr/bin/env bash
set -euo pipefail

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"

for path in "$SETTINGS" "$DOWNLOAD"; do
    test -f "$path"
done

python3 - "$SETTINGS" "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys

settings = Path(sys.argv[1])
download = Path(sys.argv[2])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def function_range(text: str, signature: str):
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"function not found: {signature}")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"opening brace not found: {signature}")
    depth = 0
    in_string = False
    escape = False
    i = brace
    while i < len(text):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return start, i + 1
        i += 1
    raise SystemExit(f"closing brace not found: {signature}")


def replace_in_function(text: str, signature: str, old: str, new: str, label: str) -> str:
    start, end = function_range(text, signature)
    block = text[start:end]
    if new in block and old not in block:
        return text
    count = block.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one function-local anchor, found {count}")
    block = block.replace(old, new, 1)
    return text[:start] + block + text[end:]


# ---------------------------------------------------------------------------
# Settings: exact pre-v2.4 visible Download Search Source choices.
# Spotify remains an internal v2.4 enum value for deep-link compatibility, but
# it is not exposed in the legacy picker.
# ---------------------------------------------------------------------------
ss = settings.read_text()
old_settings_enum = '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
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
new_settings_enum = '''private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
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
'''
ss = replace_once(ss, old_settings_enum, new_settings_enum, "legacy download settings provider list")
settings.write_text(ss)


# ---------------------------------------------------------------------------
# DownloadView provider surface. Keep raw `all` special-cased so we do not
# rewrite v2.4's entire exhaustive switch graph merely to represent aggregation.
# YouTube must be a real SearchProvider because DownloadTrack.provider carries
# it through preview/download selection.
# ---------------------------------------------------------------------------
dv = download.read_text()
old_enum = '''    enum SearchProvider: String, CaseIterable, Identifiable {
        case appleMusic
        case spotify
        case tidal
        case metadata

        static var allCases: [SearchProvider] {
            [.appleMusic, .metadata]
        }
'''
new_enum = '''    enum SearchProvider: String, CaseIterable, Identifiable {
        case appleMusic
        case spotify
        case tidal
        case metadata
        case youtube

        static var allCases: [SearchProvider] {
            [.appleMusic, .tidal, .metadata, .youtube]
        }
'''
dv = replace_once(dv, old_enum, new_enum, "DownloadView SearchProvider cases")

dv = replace_once(
    dv,
    '            case .metadata: return "iTunes + Deezer"\n',
    '            case .metadata: return "iTunes + Deezer"\n            case .youtube: return "YouTube"\n',
    "SearchProvider title YouTube",
)
dv = replace_once(
    dv,
    '            case .metadata: return "Search iTunes and Deezer"\n',
    '            case .metadata: return "Search iTunes and Deezer"\n            case .youtube: return "Search YouTube for unreleased and custom songs"\n',
    "SearchProvider placeholder YouTube",
)
dv = replace_once(
    dv,
    '            case .metadata: return "Search iTunes and Deezer and tap download"\n',
    '            case .metadata: return "Search iTunes and Deezer and tap download"\n            case .youtube: return "Search YouTube for unreleased tracks and custom songs"\n',
    "SearchProvider empty-state YouTube",
)

dv = replace_once(
    dv,
    '            return provider == .tidal ? .appleMusic : provider\n',
    '            return provider\n',
    "stop remapping Tidal to Apple Music",
)
dv = replace_once(
    dv,
    '            if searchProviderRaw == SearchProvider.tidal.rawValue || searchProviderRaw == SearchProvider.spotify.rawValue {\n                searchProviderRaw = SearchProvider.appleMusic.rawValue\n            }\n',
    '            if searchProviderRaw == SearchProvider.spotify.rawValue {\n                searchProviderRaw = SearchProvider.appleMusic.rawValue\n            }\n',
    "stop resetting Tidal on open",
)

# The earlier metadata-restoration patch adds these helpers. Correct their
# semantics to the actual pre-v2.4 provider surface.
dv = replace_once(
    dv,
    '''    private var configuredSearchPlaceholder: String {
        if searchProviderRaw == "all" {
            return "Search Apple Music, iTunes, and Deezer"
        }
        return searchProvider.searchPlaceholder
    }
''',
    '''    private var configuredSearchPlaceholder: String {
        if searchProviderRaw == "all" {
            return "Search all available sources"
        }
        return searchProvider.searchPlaceholder
    }
''',
    "All Sources placeholder parity",
)
dv = replace_once(
    dv,
    '''    private func performConfiguredSearch() {
        Task {
            if searchProviderRaw == "all" {
                await vm.searchAllSourcesCompat(query: query)
            } else {
                await vm.search(query: query, provider: searchProvider)
            }
        }
    }
''',
    '''    private func performConfiguredSearch() {
        Task {
            if searchProviderRaw == "all" {
                await vm.searchAllLegacySourcesCompat(query: query)
            } else if searchProviderRaw == "youtube" {
                await vm.searchYouTubeLegacyCompat(query: query)
            } else {
                await vm.search(query: query, provider: searchProvider)
            }
        }
    }
''',
    "configured legacy provider search",
)
dv = replace_once(
    dv,
    '''            if newValue == "all" {
                Task { await vm.searchAllSourcesCompat(query: query) }
            } else {
                let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
                Task { await vm.search(query: query, provider: provider) }
            }
''',
    '''            if newValue == "all" {
                Task { await vm.searchAllLegacySourcesCompat(query: query) }
            } else if newValue == "youtube" {
                Task { await vm.searchYouTubeLegacyCompat(query: query) }
            } else {
                let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
                Task { await vm.search(query: query, provider: provider) }
            }
''',
    "provider-change legacy routing",
)

# Album/playlist browsing for YouTube was metadata-derived in the old app. The
# compatibility search supplies pseudo albums but no standalone playlists.
dv = replace_in_function(
    dv,
    "    func loadTracks(for album: DownloadAlbum) async -> [DownloadTrack] {",
    '        case .metadata:\n',
    '        case .youtube:\n            return []\n        case .metadata:\n',
    "YouTube album switch",
)
dv = replace_in_function(
    dv,
    "    func loadTracks(for playlist: DownloadAlbum, isPlaylist: Bool) async -> [DownloadTrack] {",
    '        case .tidal, .metadata:\n            return []\n',
    '        case .tidal, .metadata, .youtube:\n            return []\n',
    "YouTube playlist switch",
)

# Search and pagination. YouTube search itself lives in the compatibility file;
# pagination is intentionally disabled because the public fallback APIs do not
# expose the same stable continuation contract once YouTubeKit is removed.
dv = replace_in_function(
    dv,
    "    func search(query: String, provider: DownloadView.SearchProvider) async {",
    '        case .metadata:\n',
    '        case .youtube:\n            await searchYouTubeLegacyCompat(query: trimmed)\n\n        case .metadata:\n',
    "YouTube main search branch",
)
dv = replace_in_function(
    dv,
    "    func loadMoreSongs() async {",
    '        case .metadata:\n',
    '        case .youtube:\n            canLoadMoreSongs = false\n        case .metadata:\n',
    "YouTube song pagination branch",
)
dv = replace_in_function(
    dv,
    "    func loadMoreAlbums() async {",
    '        case .metadata:\n',
    '        case .youtube:\n            canLoadMoreAlbums = false\n        case .metadata:\n',
    "YouTube album pagination branch",
)
dv = replace_in_function(
    dv,
    "    func loadMorePlaylists() async {",
    '        case .tidal, .metadata:\n            canLoadMorePlaylists = false\n',
    '        case .tidal, .metadata, .youtube:\n            canLoadMorePlaylists = false\n',
    "YouTube playlist pagination branch",
)
dv = replace_in_function(
    dv,
    "    func loadArtistProfile(for artist: DownloadArtist) async -> DownloadArtistProfile {",
    '        case .tidal, .metadata, .spotify:\n            return await buildMetadataArtistProfile(for: artist.name)\n',
    '        case .tidal, .metadata, .spotify, .youtube:\n            return await buildMetadataArtistProfile(for: artist.name)\n',
    "YouTube artist-profile branch",
)

# Preview/audio resolution: this is the pre-v2.4 distinction that prevents a
# YouTube result from being treated as an iTunes preview candidate.
dv = replace_once(
    dv,
    '''        switch track.provider {
        case .appleMusic, .spotify, .metadata, .tidal:
            resolved = await resolveITunesPreviewURL(for: track)
        }
''',
    '''        switch track.provider {
        case .appleMusic, .spotify, .metadata, .tidal:
            resolved = await resolveITunesPreviewURL(for: track)
        case .youtube:
            if let videoID = MetadataProvider.extractYouTubeVideoID(from: track.sourceURL) {
                resolved = await MetadataProvider.resolveYouTubeAudioStreamURLCompat(videoID: videoID)
            } else {
                resolved = nil
            }
        }
''',
    "YouTube preview/audio resolver branch",
)

download.write_text(dv)
PY

# Fail closed: these markers define the restored visible contract and ensure
# the old reduced All implementation cannot silently reappear.
grep -Fq 'case youtube' "$SETTINGS"
grep -Fq '[.appleMusic, .tidal, .metadata, .youtube, .all]' "$SETTINGS"
grep -Fq 'case youtube' "$DOWNLOAD"
grep -Fq 'Search YouTube for unreleased and custom songs' "$DOWNLOAD"
grep -Fq 'searchAllLegacySourcesCompat' "$DOWNLOAD"
grep -Fq 'searchYouTubeLegacyCompat' "$DOWNLOAD"
grep -Fq 'resolveYouTubeAudioStreamURLCompat' "$DOWNLOAD"
grep -Fq 'case .tidal, .metadata, .spotify, .youtube:' "$DOWNLOAD"
! grep -Fq 'Search Apple Music, iTunes, and Deezer' "$DOWNLOAD"
! grep -Fq 'return provider == .tidal ? .appleMusic : provider' "$DOWNLOAD"

echo 'Applied pre-v2.4 ByeTunes download-provider parity'
