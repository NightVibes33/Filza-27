#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
SONG="$ROOT/SongMetadata.swift"
LYRICS="$ROOT/LyricsSearchSheet.swift"
ITUNES="$ROOT/iTunesSearchSheet.swift"
SETTINGS="$ROOT/SettingsView.swift"
MEDIA="$ROOT/MediaLibraryBuilder.swift"
EDITOR="$ROOT/ManualMetadataEditor.swift"
QUEUE="$ROOT/QueuePersistence.swift"

for file in "$SONG" "$LYRICS" "$ITUNES" "$SETTINGS" "$MEDIA" "$EDITOR" "$QUEUE"; do
  test -s "$file" || {
    echo "missing ByeTunes source: $file" >&2
    exit 1
  }
done

python3 - "$SONG" "$LYRICS" "$ITUNES" "$SETTINGS" "$MEDIA" "$EDITOR" "$QUEUE" <<'PY'
from pathlib import Path
import sys

song = Path(sys.argv[1])
lyrics = Path(sys.argv[2])
itunes = Path(sys.argv[3])
settings = Path(sys.argv[4])
media = Path(sys.argv[5])
editor = Path(sys.argv[6])
queue = Path(sys.argv[7])

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

def balanced_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit("opening brace not found")
    depth = 0
    in_string = False
    escaped = False
    i = brace
    while i < len(text):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit("unbalanced Swift block")

sm = song.read_text()

if "var appleSyncedLyricsStoreID: Int64 = 0" not in sm:
    sm = replace_once(
        sm,
        "    var lyrics: String?\n",
        "    var lyrics: String?\n    var appleSyncedLyricsStoreID: Int64 = 0\n",
        "per-song Apple synced lyrics catalog ID"
    )

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

caller_start = sm.find('        let fetchLyricsEnabled = UserDefaults.standard.bool(forKey: "fetchLyrics")')
if caller_start >= 0 and "Verified Apple Music TTML for per-song catalog lyrics" not in sm[caller_start:caller_start + 4200]:
    caller_if = sm.find("        if fetchLyricsEnabled", caller_start)
    if caller_if < 0:
        raise SystemExit("automatic lyric enrichment block missing")
    caller_end = balanced_end(sm, caller_if)

    caller_replacement = '''        let fetchLyricsEnabled = UserDefaults.standard.object(forKey: "fetchLyrics") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "fetchLyrics")
        let appleSubscriptionLyrics = UserDefaults.standard.object(forKey: "appleSubscriptionLyrics") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")

        if (fetchLyricsEnabled || appleSubscriptionLyrics) && (song.lyrics == nil || song.lyrics?.isEmpty == true) {
            var usedAppleSyncedLyrics = false

            if appleSubscriptionLyrics,
               AppleMusicSyncedLyricsCredentialStore.isConnected {
                let query = "\(song.artist) \(song.title)"
                if let match = await AppleMusicAPI.shared.searchSong(query: query, albumHint: song.album),
                   let storeID = Int64(match.id),
                   let appleLyrics = await AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics(songID: match.id),
                   !appleLyrics.isEmpty {
                    song.appleSyncedLyricsStoreID = storeID
                    song.storeId = storeID
                    if song.storefrontId == 0 {
                        let region = (UserDefaults.standard.string(forKey: "storeRegion") ?? "US").lowercased()
                        song.storefrontId = SongMetadata.storefrontMap[region] ?? 0
                    }
                    song.lyrics = appleLyrics
                    usedAppleSyncedLyrics = true
                    Logger.shared.log("[SongMetadata] Verified Apple Music TTML for per-song catalog lyrics id=\(match.id)")
                }
            }

            if !usedAppleSyncedLyrics && fetchLyricsEnabled,
               let fallbackLyrics = await SongMetadata.fetchLyricsFromLRCLIB(
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    durationMs: song.durationMs
               ) {
                song.appleSyncedLyricsStoreID = 0
                song.lyrics = fallbackLyrics
                Logger.shared.log("[SongMetadata] Apple synced lyrics unavailable; using LRCLIB fallback")
            }
        }'''

    sm = sm[:caller_start] + caller_replacement + sm[caller_end:]

# A manual Apple metadata match must carry the same per-song lyric identity.
apply_sig = "    static func applyAppleMusicMatch(_ match: AppleMusicAPI.AppleMusicSong, to song: SongMetadata) async -> SongMetadata {"
apply_start = sm.find(apply_sig)
if apply_start < 0:
    raise SystemExit("applyAppleMusicMatch missing")
apply_end = balanced_end(sm, apply_start)
apply_block = sm[apply_start:apply_end]
if "Apple metadata selector verified synced TTML" not in apply_block:
    return_pos = apply_block.rfind("        return enrichedSong")
    if return_pos < 0:
        raise SystemExit("applyAppleMusicMatch return missing")
    apple_metadata_lyrics = '''        if UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics"),
           AppleMusicSyncedLyricsCredentialStore.isConnected,
           let appleStoreID = Int64(amsMatch.id),
           let verifiedAppleLyrics = await AppleMusicSyncedLyricsClient.shared.fetchSyncedLyrics(songID: amsMatch.id),
           !verifiedAppleLyrics.isEmpty {
            enrichedSong.appleSyncedLyricsStoreID = appleStoreID
            if enrichedSong.lyrics == nil || enrichedSong.lyrics?.isEmpty == true {
                enrichedSong.lyrics = verifiedAppleLyrics
            }
            Logger.shared.log("[SongMetadata] Apple metadata selector verified synced TTML id=\(amsMatch.id)")
        }

'''
    apply_block = apply_block[:return_pos] + apple_metadata_lyrics + apply_block[return_pos:]
    sm = sm[:apply_start] + apply_block + sm[apply_end:]

song.write_text(sm)

ls = lyrics.read_text()
if "var onAppleMusicSelection: ((String) -> Void)? = nil" not in ls:
    ls = replace_once(
        ls,
        "    let songArtist: String\n",
        "    let songArtist: String\n    var onAppleMusicSelection: ((String) -> Void)? = nil\n    var onLocalLyricsSelection: (() -> Void)? = nil\n",
        "lyrics selector source callbacks"
    )

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
                    if result.service == .appleMusic, let appleMusicID = result.appleMusicID {
                        self.onAppleMusicSelection?(appleMusicID)
                    } else {
                        self.onLocalLyricsSelection?()
                    }
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

ed = editor.read_text()
if "@State private var appleSyncedLyricsStoreID: Int64 = 0" not in ed:
    ed = replace_once(
        ed,
        '    @State private var lyrics: String = ""\n',
        '    @State private var lyrics: String = ""\n    @State private var appleSyncedLyricsStoreID: Int64 = 0\n',
        "manual editor Apple lyric ID state"
    )

if "onAppleMusicSelection:" not in ed:
    ed = replace_once(
        ed,
        '                LyricsSearchSheet(lyrics: $lyrics, isPresented: $showingLyricsSearchSheet, songTitle: title, songArtist: artist)\n',
        '''                LyricsSearchSheet(
                    lyrics: $lyrics,
                    isPresented: $showingLyricsSearchSheet,
                    songTitle: title,
                    songArtist: artist,
                    onAppleMusicSelection: { appleMusicID in
                        if let storeID = Int64(appleMusicID) {
                            appleSyncedLyricsStoreID = storeID
                            song.storeId = storeID
                            if song.storefrontId == 0 {
                                let region = (UserDefaults.standard.string(forKey: "storeRegion") ?? "US").lowercased()
                                song.storefrontId = SongMetadata.storefrontMap[region] ?? 0
                            }
                        }
                    },
                    onLocalLyricsSelection: {
                        appleSyncedLyricsStoreID = 0
                    }
                )
''',
        "manual editor lyric selector callbacks"
    )

if "appleSyncedLyricsStoreID = song.appleSyncedLyricsStoreID" not in ed:
    ed = replace_once(
        ed,
        '        lyrics = song.lyrics ?? ""\n',
        '        lyrics = song.lyrics ?? ""\n        appleSyncedLyricsStoreID = song.appleSyncedLyricsStoreID\n',
        "manual editor load Apple lyric ID"
    )

if "updatedSong.appleSyncedLyricsStoreID = appleSyncedLyricsStoreID" not in ed:
    ed = replace_once(
        ed,
        "        updatedSong.lyrics = lyrics.isEmpty ? nil : lyrics\n",
        "        updatedSong.lyrics = lyrics.isEmpty ? nil : lyrics\n        updatedSong.appleSyncedLyricsStoreID = appleSyncedLyricsStoreID\n",
        "manual editor save Apple lyric ID"
    )

editor.write_text(ed)

qs = queue.read_text()
if "var appleSyncedLyricsStoreID: Int64?" not in qs:
    qs = replace_once(
        qs,
        "    var lyrics: String?\n    var explicitRating: Int\n",
        "    var lyrics: String?\n    var appleSyncedLyricsStoreID: Int64?\n    var explicitRating: Int\n",
        "queue Apple lyric ID field"
    )
    qs = replace_once(
        qs,
        "        self.lyrics = song.lyrics\n        self.explicitRating = song.explicitRating\n",
        "        self.lyrics = song.lyrics\n        self.appleSyncedLyricsStoreID = song.appleSyncedLyricsStoreID\n        self.explicitRating = song.explicitRating\n",
        "queue persist Apple lyric ID"
    )
    qs = replace_once(
        qs,
        "        song.explicitRating = explicitRating\n",
        "        song.explicitRating = explicitRating\n        song.appleSyncedLyricsStoreID = appleSyncedLyricsStoreID ?? 0\n",
        "queue restore Apple lyric ID"
    )

queue.write_text(qs)

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
            let appleSongID = song.appleSyncedLyricsStoreID > 0
                ? String(song.appleSyncedLyricsStoreID)
                : ""
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
grep -Fq 'appleSyncedLyricsStoreID' "$SONG"
grep -Fq 'onAppleMusicSelection' "$LYRICS"
grep -Fq 'appleSyncedLyricsStoreID' "$EDITOR"
grep -Fq 'appleSyncedLyricsStoreID' "$QUEUE"
! grep -Fq "VALUES (\(itemPid), '\(lyricsContent)', 1, 1" "$MEDIA"

echo "Verified Apple Music selector + direct TTML + truthful library sync flags"
