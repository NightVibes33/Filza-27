#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1])
def replace(s,a,b):
    if s.count(a)!=1: raise SystemExit('Missing or ambiguous patch anchor: '+a[:100])
    return s.replace(a,b,1)
p=r/'SongMetadata.swift';s=p.read_text()
if 'static func catalogAwareNativeLyricsPayload(' in s: sys.exit(0)
helper='''    // Catalog resolution remains subject to Apple's normal account entitlement checks.
    static func catalogAwareNativeLyricsPayload(text: String?, timedTTML: String?, durationMs: Int,
                                                catalogMatched: Bool) -> (text: String, timed: Bool, store: Bool) {
        if catalogMatched { return ("", true, true) }
        let local = nativeLibraryLyricsPayload(text: text, timedTTML: timedTTML, durationMs: durationMs)
        return (local.text, false, false)
    }

'''
s=replace(s,'    static func nativeLibraryLyricsPayload(',helper+'    static func nativeLibraryLyricsPayload(')
s=replace(s,'static func rememberNativeLyricDocument(for song: SongMetadata)', 'static func rememberNativeLyricDocument(for song: SongMetadata, catalogMatched: Bool = false)')
s=replace(s,'"source": song.syncedLyricsSource ?? "saved-ttml", "timing": state.timing', '"source": song.syncedLyricsSource ?? "saved-ttml", "timing": state.timing, "catalog": catalogMatched ? "1" : "0"')
s=replace(s,'cached["text"] == cleanLyrics(song.lyrics ?? ""), let document = cached["ttml"],', '(cached["text"] == cleanLyrics(song.lyrics ?? "") || (cached["catalog"] == "1" && cleanLyrics(song.lyrics ?? "").isEmpty)), let document = cached["ttml"],')
s=replace(s,'        song.syncedLyricsTTML = document', '        song.lyrics = cached["text"]\n        song.syncedLyricsTTML = document')
p.write_text(s)
p=r/'MediaLibraryBuilder.swift';s=p.read_text()
s=replace(s,'let lyricPayload = SongMetadata.nativeLibraryLyricsPayload(','let lyricPayload = SongMetadata.catalogAwareNativeLyricsPayload(')
s=replace(s,'text: song.lyrics, timedTTML: song.syncedLyricsTTML, durationMs: song.durationMs)',
          'text: song.lyrics, timedTTML: song.syncedLyricsTTML, durationMs: song.durationMs,\n                catalogMatched: hasAppleCatalogMatch)')
s=replace(s,'SongMetadata.rememberNativeLyricDocument(for: song)', 'SongMetadata.rememberNativeLyricDocument(for: song, catalogMatched: hasAppleCatalogMatch)')
s=replace(s,'let storeLyricsAvailable = 0','let storeLyricsAvailable = lyricPayload.store ? 1 : 0');p.write_text(s)
p=r/'iDeviceManager.swift';s=p.read_text()
s=replace(s,'            let lyricPayload = SongMetadata.nativeLibraryLyricsPayload(','''            // Use the persisted catalog association; never invent a catalog ID during editing.
            let persistedCatalogId = self.firstStringQuery(db: db,
                sql: "SELECT CAST(store_item_id AS TEXT) FROM item_store WHERE item_pid = ? LIMIT 1", itemPid: itemPid)
            let hasNativeCatalogMatch = (Int64(persistedCatalogId ?? "0") ?? 0) > 0
            let lyricPayload = SongMetadata.catalogAwareNativeLyricsPayload(''')
s=replace(s,'durationMs: updatedSong.durationMs)','durationMs: updatedSong.durationMs, catalogMatched: hasNativeCatalogMatch)')
s=replace(s,'            let timedLyricsAvailable = lyricPayload.timed ? 1 : 0','            let timedLyricsAvailable = lyricPayload.timed ? 1 : 0\n            let storeLyricsAvailable = lyricPayload.store ? 1 : 0')
s=replace(s,"VALUES (\\(itemPid), '\\(escapedLyrics)', 0, \\(timedLyricsAvailable))","VALUES (\\(itemPid), '\\(escapedLyrics)', \\(storeLyricsAvailable), \\(timedLyricsAvailable))")
s=replace(s,'SongMetadata.rememberNativeLyricDocument(for: updatedSong)', 'SongMetadata.rememberNativeLyricDocument(for: updatedSong, catalogMatched: hasNativeCatalogMatch)')
s=replace(s,'                lyricMatches = actual == expectedLyrics && flag == (expectedTimedLyrics ? "1" : "0")', '                let storeFlag = self.firstStringQuery(db: db, sql: "SELECT CAST(store_lyrics_available AS TEXT) FROM lyrics WHERE item_pid = ? LIMIT 1", itemPid: itemPid)\n                let downloadedFlag = self.firstStringQuery(db: db, sql: "SELECT CAST(downloaded_catalog_lyrics_available AS TEXT) FROM lyrics WHERE item_pid = ? LIMIT 1", itemPid: itemPid)\n                lyricMatches = actual == expectedLyrics && flag == (expectedTimedLyrics ? "1" : "0") && storeFlag == flag && (downloadedFlag == nil || downloadedFlag == "0")')
p.write_text(s)
p=r/'SettingsView.swift';s=p.read_text()
s=s.replace('Retain timed lyrics in Filza; Apple Music displays plain lyrics.', 'Matched songs use Apple catalog lyrics; other songs use provider lyrics.')
s=s.replace('Free lyric pipeline: AMLL TTML by Apple Music catalog ID first, then LRCLIB synced LRC, then plain lyrics. No Apple Music subscription, Apple login, media-user-token, or music.apple.com cookie is used.', "Matched tracks use Music.app's catalog lyric resolution, subject to Apple's account checks. For other tracks, free providers supply lyrics; original timing stays in Filza and Apple Music receives readable text.")
p.write_text(s)
print('Catalog lyric resolution restored; existing on-device pairing and replay onboarding preserved')
PY
