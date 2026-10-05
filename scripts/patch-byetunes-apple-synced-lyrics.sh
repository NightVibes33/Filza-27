#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
SONG="$ROOT/SongMetadata.swift"
LYRICS="$ROOT/LyricsSearchSheet.swift"
ITUNES="$ROOT/iTunesSearchSheet.swift"
SETTINGS="$ROOT/SettingsView.swift"
MEDIA="$ROOT/MediaLibraryBuilder.swift"

for file in "$SONG" "$LYRICS" "$ITUNES" "$SETTINGS" "$MEDIA"; do
  test -s "$file" || {
    echo "missing ByeTunes source: $file" >&2
    exit 1
  }
done

python3 - "$SONG" "$LYRICS" "$ITUNES" "$SETTINGS" "$MEDIA" <<'PY'
from pathlib import Path
import sys

song = Path(sys.argv[1])
lyrics = Path(sys.argv[2])
itunes = Path(sys.argv[3])
settings = Path(sys.argv[4])
media = Path(sys.argv[5])

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

sm = song.read_text()

enum_old = '''enum LyricsSearchService: String, CaseIterable, Identifiable {
    case lrclib
    case musixmatch
    case netease

    static var allCases: [LyricsSearchService] { [.lrclib] }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lrclib:
            return "LRCLIB"
        case .musixmatch:
            return "Musixmatch"
        case .netease:
            return "NetEase"
        }
    }
}
'''
enum_new = '''enum LyricsSearchService: String, CaseIterable, Identifiable {
    case appleMusic
    case lrclib
    case musixmatch
    case netease

    static var allCases: [LyricsSearchService] { [.appleMusic, .lrclib] }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music Synced"
        case .lrclib:
            return "LRCLIB"
        case .musixmatch:
            return "Musixmatch"
        case .netease:
            return "NetEase"
        }
    }
}
'''
if "case appleMusic" not in sm:
    sm = replace_once(sm, enum_old, enum_new, "Apple lyrics provider enum")

result_old = '''struct LyricsSearchResult: Identifiable {
    let id: String
    let service: LyricsSearchService
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int?
    let hasSyncedLyrics: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let remoteID: Int?
}
'''
result_new = '''struct LyricsSearchResult: Identifiable {
    let id: String
    let service: LyricsSearchService
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int?
    let hasSyncedLyrics: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let remoteID: Int?
    var appleMusicID: String? = nil
}
'''
if "var appleMusicID: String? = nil" not in sm:
    sm = replace_once(sm, result_old, result_new, "Apple lyrics result identity")

search_switch_old = '''        switch service {
        case .lrclib:
            return await searchLyricsFromLRCLIB(query: query)
        case .musixmatch:
            return await searchLyricsFromMusixMatch(query: query)
        case .netease:
            return await searchLyricsFromNetEase(query: query)
        }
'''
search_switch_new = '''        switch service {
        case .appleMusic:
            return await searchLyricsFromAppleMusic(query: query)
        case .lrclib:
            return await searchLyricsFromLRCLIB(query: query)
        case .musixmatch:
            return await searchLyricsFromMusixMatch(query: query)
        case .netease:
            return await searchLyricsFromNetEase(query: query)
        }
'''
if "return await searchLyricsFromAppleMusic(query: query)" not in sm:
    sm = replace_once(sm, search_switch_old, search_switch_new, "Apple lyrics search switch")

resolve_switch_old = '''        switch result.service {
        case .lrclib:
            if let synced = result.syncedLyrics,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = cleanSyncedLyrics(synced, title: songTitle, artist: songArtist)
                return cleaned.isEmpty ? nil : cleaned
            }
            let cleaned = cleanLyrics(result.plainLyrics ?? "", title: songTitle, artist: songArtist)
            return cleaned.isEmpty ? nil : cleaned
        case .musixmatch:
            guard let remoteID = result.remoteID else { return nil }
            return await fetchLyricsFromMusixMatchTrackID(remoteID, title: songTitle, artist: songArtist)
        case .netease:
            guard let remoteID = result.remoteID else { return nil }
            return await fetchLyricsFromNetEaseTrackID(remoteID, title: songTitle, artist: songArtist)
        }
'''
resolve_switch_new = '''        switch result.service {
        case .appleMusic:
            guard let appleMusicID = result.appleMusicID else { return nil }
            return await AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics(songID: appleMusicID)
        case .lrclib:
            if let synced = result.syncedLyrics,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = cleanSyncedLyrics(synced, title: songTitle, artist: songArtist)
                return cleaned.isEmpty ? nil : cleaned
            }
            let cleaned = cleanLyrics(result.plainLyrics ?? "", title: songTitle, artist: songArtist)
            return cleaned.isEmpty ? nil : cleaned
        case .musixmatch:
            guard let remoteID = result.remoteID else { return nil }
            return await fetchLyricsFromMusixMatchTrackID(remoteID, title: songTitle, artist: songArtist)
        case .netease:
            guard let remoteID = result.remoteID else { return nil }
            return await fetchLyricsFromNetEaseTrackID(remoteID, title: songTitle, artist: songArtist)
        }
'''
if "AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics" not in sm:
    sm = replace_once(sm, resolve_switch_old, resolve_switch_new, "Apple lyrics resolve switch")

apple_search = '''    private static func searchLyricsFromAppleMusic(query: String) async -> [LyricsSearchResult] {
        let matches = await AppleMusicAPI.shared.searchSongs(query: query, limit: 12)
        var results: [LyricsSearchResult] = []

        for match in matches {
            let synced = await AppleMusicSyncedLyricsClient.shared.hasTimeSyncedLyrics(songID: match.id)
            guard synced else { continue }

            var result = LyricsSearchResult(
                id: "applemusic-\(match.id)",
                service: .appleMusic,
                title: match.attributes.name,
                artist: match.attributes.artistName,
                album: match.attributes.albumName,
                durationMs: match.attributes.durationInMillis,
                hasSyncedLyrics: true,
                plainLyrics: nil,
                syncedLyrics: nil,
                remoteID: nil
            )
            result.appleMusicID = match.id
            results.append(result)
        }

        return results
    }

'''
marker = "    private static func searchLyricsFromLRCLIB(query: String) async -> [LyricsSearchResult] {"
if "private static func searchLyricsFromAppleMusic" not in sm:
    if marker not in sm:
        raise SystemExit("Apple lyrics search insertion marker missing")
    sm = sm.replace(marker, apple_search + marker, 1)

auto_old = '''    static func fetchLyrics(title: String, artist: String, album: String, durationMs: Int) async -> String? {
        await fetchLyricsFromLRCLIB(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }'''
auto_new = '''    static func fetchLyrics(title: String, artist: String, album: String, durationMs: Int) async -> String? {
        if UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics"),
           AppleMusicSyncedLyricsCredentialStore.isConnected {
            let query = "\(artist) \(title)"
            if let match = await AppleMusicAPI.shared.searchSong(query: query, albumHint: album),
               let appleLyrics = await AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics(songID: match.id),
               !appleLyrics.isEmpty {
                Logger.shared.log("[SongMetadata] Using Apple Music synced lyrics for \(artist) - \(title)")
                return appleLyrics
            }
            Logger.shared.log("[SongMetadata] Apple synced lyrics unavailable; falling back to LRCLIB")
        }

        return await fetchLyricsFromLRCLIB(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
    }'''
if "Apple synced lyrics unavailable; falling back to LRCLIB" not in sm:
    sm = replace_once(sm, auto_old, auto_new, "Apple-first automatic lyrics")

sm = sm.replace(
    'if fetchLyricsEnabled && !appleSubscriptionLyrics && (song.lyrics == nil || song.lyrics?.isEmpty == true) {',
    'if (fetchLyricsEnabled || appleSubscriptionLyrics) && (song.lyrics == nil || song.lyrics?.isEmpty == true) {'
)
song.write_text(sm)

ls = lyrics.read_text()
ls = ls.replace(
    '@State private var lyricsService: LyricsSearchService = .lrclib',
    '@State private var lyricsService: LyricsSearchService = .appleMusic'
)

if "@State private var showingAppleMusicLogin = false" not in ls:
    ls = ls.replace(
        '@State private var errorMessage: String?\n',
        '@State private var errorMessage: String?\n    @State private var showingAppleMusicLogin = false\n    @State private var pendingAppleMusicResult: LyricsSearchResult?\n',
        1
    )

old_apply = '''    private func applyLyricsResult(_ result: LyricsSearchResult) {
        isResolvingLyrics = true
        errorMessage = nil

        Task {
            let fetchedLyrics = await SongMetadata.resolveLyrics(for: result, songTitle: songTitle, songArtist: songArtist)
            await MainActor.run {
                self.isResolvingLyrics = false
                if let fetchedLyrics, !fetchedLyrics.isEmpty {
                    Logger.shared.log("[LyricsSearch] Fetched lyrics from \(result.service.displayName)")
                    self.lyrics = fetchedLyrics
                    self.isPresented = false
                } else {
                    self.errorMessage = "Couldn’t load lyrics from \(result.service.displayName). Try another result or service."
                }
            }
        }
    }
'''
new_apply = '''    private func applyLyricsResult(_ result: LyricsSearchResult) {
        if result.service == .appleMusic && !AppleMusicSyncedLyricsCredentialStore.isConnected {
            pendingAppleMusicResult = result
            showingAppleMusicLogin = true
            return
        }

        isResolvingLyrics = true
        errorMessage = nil

        Task {
            let fetchedLyrics = await SongMetadata.resolveLyrics(for: result, songTitle: songTitle, songArtist: songArtist)
            await MainActor.run {
                self.isResolvingLyrics = false
                if let fetchedLyrics, !fetchedLyrics.isEmpty {
                    Logger.shared.log("[LyricsSearch] Fetched lyrics from \(result.service.displayName)")
                    self.lyrics = fetchedLyrics
                    self.isPresented = false
                } else {
                    self.errorMessage = result.service == .appleMusic
                        ? "Apple Music synced lyrics could not be loaded. LRCLIB remains available as a fallback."
                        : "Couldn’t load lyrics from \(result.service.displayName). Try another result or service."
                }
            }
        }
    }
'''
if "pendingAppleMusicResult = result" not in ls:
    ls = replace_once(ls, old_apply, new_apply, "Apple lyrics selector login")

sheet_marker = '''        .onChange(of: lyricsService) { _ in
            results = []
            errorMessage = nil
            if !searchQuery.isEmpty {
                performSearch()
            }
        }
'''
sheet_new = sheet_marker + '''        .sheet(isPresented: $showingAppleMusicLogin) {
            AppleMusicSyncedLyricsLoginSheet { success in
                guard success, let pending = pendingAppleMusicResult else {
                    pendingAppleMusicResult = nil
                    return
                }
                pendingAppleMusicResult = nil
                DispatchQueue.main.async {
                    applyLyricsResult(pending)
                }
            }
        }
'''
if "AppleMusicSyncedLyricsLoginSheet" not in ls:
    ls = replace_once(ls, sheet_marker, sheet_new, "Apple lyrics selector sheet")
lyrics.write_text(ls)

it = itunes.read_text()
apple_row_start = it.find("struct AppleMusicRow: View {")
if apple_row_start < 0:
    raise SystemExit("AppleMusicRow missing")
apple_row_tail = it[apple_row_start:]
old_badge = '''            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
'''
new_badge = '''            Spacer()
            AppleMusicSyncedLyricsAvailabilityBadge(songID: match.id)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
'''
if "AppleMusicSyncedLyricsAvailabilityBadge(songID: match.id)" not in apple_row_tail:
    if old_badge not in apple_row_tail:
        raise SystemExit("AppleMusicRow chevron marker missing")
    apple_row_tail = apple_row_tail.replace(old_badge, new_badge, 1)
    it = it[:apple_row_start] + apple_row_tail
itunes.write_text(it)

st = settings.read_text()
st = st.replace("if !appleSubscriptionLyrics {", "if true {", 1)
st = st.replace('Text("Apple Music Subscription Lyrics")', 'Text("Apple Music Synced Lyrics")', 1)
st = st.replace('Text("Use Apple Music\'s synced lyrics.")', 'Text("Apple first, LRCLIB fallback.")', 1)
st = st.replace(
    '"Apple Music Subscription Lyrics",\n                                        "If you have an active Apple Music subscription, use Apple\'s own time-synced lyrics instead of the community sources above. Requires an internet connection."',
    '"Apple Music Synced Lyrics",\n                                        "Uses Apple\'s direct syllable-lyrics TTML when your Apple Music account can access it. ByeTunes handles the token locally and automatically falls back to LRCLIB when Apple lyrics are unavailable."',
    1
)

connection_marker = '''                        if metadataSource == "itunes" || metadataSource == "apple" || (metadataSource == "local" && appleRichMetadata) {
'''
connection_block = '''                        Divider().padding(.leading, 56)

                        AppleMusicSyncedLyricsConnectionRow()

'''
if "AppleMusicSyncedLyricsConnectionRow()" not in st:
    if connection_marker not in st:
        raise SystemExit("settings Apple connection insertion marker missing")
    st = st.replace(connection_marker, connection_block + connection_marker, 1)
settings.write_text(st)

mb = media.read_text()
lyrics_block_old = '''            let appleSubscriptionLyrics = UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")
            let resolvedLyricsText = appleSubscriptionLyrics ? "" : SongMetadata.cleanLyrics(song.lyrics ?? "", title: song.title, artist: song.artist)
            let lyricsContent = resolvedLyricsText.replacingOccurrences(of: "'", with: "''")

            if columnExists(db: db, tableName: "lyrics", columnName: "downloaded_catalog_lyrics_available") {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available, downloaded_catalog_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', 1, 1, 0)
                """)
            } else {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', 1, 1)
                """)
            }
'''
lyrics_block_new = '''            let appleSubscriptionLyrics = UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")
            let appleSongID = song.storeId > 0 ? String(song.storeId) : ""
            let appleSyncedLyricsConfirmed =
                appleSubscriptionLyrics &&
                !appleSongID.isEmpty &&
                AppleMusicSyncedLyricsAccessCache.contains(songID: appleSongID)

            let resolvedLyricsText = appleSyncedLyricsConfirmed
                ? ""
                : SongMetadata.cleanLyrics(song.lyrics ?? "", title: song.title, artist: song.artist)
            let lyricsContent = resolvedLyricsText.replacingOccurrences(of: "'", with: "''")
            let storeLyricsAvailable = appleSyncedLyricsConfirmed ? 1 : 0
            let timeSyncedLyricsAvailable = appleSyncedLyricsConfirmed ? 1 : 0

            if columnExists(db: db, tableName: "lyrics", columnName: "downloaded_catalog_lyrics_available") {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available, downloaded_catalog_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', \(storeLyricsAvailable), \(timeSyncedLyricsAvailable), 0)
                """)
            } else {
                try executeSQL(db, """
                    INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available)
                    VALUES (\(itemPid), '\(lyricsContent)', \(storeLyricsAvailable), \(timeSyncedLyricsAvailable))
                """)
            }
'''
if "appleSyncedLyricsConfirmed" not in mb:
    mb = replace_once(mb, lyrics_block_old, lyrics_block_new, "truthful Apple synced lyrics database flags")
media.write_text(mb)

print("Applied Apple Music direct synced-lyrics integration")
PY

grep -Fq 'case appleMusic' "$SONG"
grep -Fq 'static var allCases: [LyricsSearchService] { [.appleMusic, .lrclib] }' "$SONG"
grep -Fq 'searchLyricsFromAppleMusic' "$SONG"
grep -Fq 'AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics' "$SONG"
grep -Fq 'fetchLyricsEnabled || appleSubscriptionLyrics' "$SONG"
grep -Fq 'AppleMusicSyncedLyricsAvailabilityBadge' "$ITUNES"
grep -Fq 'AppleMusicSyncedLyricsConnectionRow' "$SETTINGS"
grep -Fq 'appleSyncedLyricsConfirmed' "$MEDIA"
! grep -Fq "VALUES (\(itemPid), '\(lyricsContent)', 1, 1" "$MEDIA"

echo "Verified Apple Music selector + direct TTML + truthful library sync flags"
