#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=r/'SongMetadata.swift';s=p.read_text()
if 'static func editorLyricsState(' in s:sys.exit(0)
helper=r'''
    static func editorLyricsState(text: String?, timedTTML: String?) -> (text: String, ttml: String?, timing: String) {
        for candidate in [timedTTML, text] {
            guard let candidate, isValidCustomTTML(candidate),
                  let plain = plainTextFromTTML(candidate) else { continue }
            let normalized = normalizeCustomTTML(candidate)
            let wordTimed = normalized.range(of: #"<span\b[^>]*\bbegin\s*="#, options: .regularExpression) != nil
            return (plain, normalized, wordTimed ? "word" : "line")
        }
        return (text ?? "", nil, isSyncedLRC(text ?? "") ? "line" : "plain")
    }

    static func searchLyricsPlusCatalog(query: String) async -> [LyricsSearchResult] {
        var url = URLComponents(string: "https://lyricsplus.prjktla.my.id/v1/songlist/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let address = url.url, let data = await publicLyricData(address),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["results"] as? [[String: Any]] else { return [] }
        return rows.prefix(50).compactMap { row in
            guard let title = row["title"] as? String, let artist = row["artist"] as? String else { return nil }
            return LyricsSearchResult(id: "lyricsplus-\(title)-\(artist)-\(row["durationMs"] ?? "")", service: .lyricsplus,
                title: title, artist: artist, album: row["album"] as? String,
                durationMs: (row["durationMs"] as? NSNumber)?.intValue, hasSyncedLyrics: true,
                plainLyrics: nil, syncedLyrics: nil, remoteID: nil)
        }
    }
'''
s=s.replace('    private static let publicLyricCache',helper+'\n    private static let publicLyricCache',1)
s=s.replace('''    static func searchPublicLyrics(query: String, service: LyricsSearchService) async -> [LyricsSearchResult] {
''','''    static func searchPublicLyrics(query: String, service: LyricsSearchService) async -> [LyricsSearchResult] {
        if service == .lyricsplus { return await searchLyricsPlusCatalog(query: query) }
''',1)
s=s.replace('Public provider HTTP \\(', 'Public provider \\(url.host ?? "unknown") HTTP \\(',1)
# lrc.red uses unqualified decimal seconds for short begin/end values.
start=s.index('    static func normalizeCustomTTML(');end=s.index('\n    }',start)
segment=s[start:end];anchor='        return text'
conversion=r'''
        let secondsPattern = #"(begin|end|dur)="([0-9]+(?:\.[0-9]+)?)""#
        if let regex = try? NSRegularExpression(pattern: secondsPattern) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed() {
                guard let attribute = Range(match.range(at: 1), in: text),
                      let value = Range(match.range(at: 2), in: text),
                      let range = Range(match.range, in: text), let seconds = Double(text[value]),
                      seconds.isFinite, seconds >= 0 else { continue }
                let replacement = "\(text[attribute])=\"\(formatTTMLTime(seconds))\""
                text.replaceSubrange(range, with: replacement)
            }
        }
'''
assert anchor in segment;segment=segment.replace(anchor,conversion+'\n'+anchor,1);s=s[:start]+segment+s[end:]
p.write_text(s)
p=r/'ManualMetadataEditor.swift';s=p.read_text()
old='''        lyrics = song.lyrics ?? ""
        chosenTTML = nil
        chosenLyricText = nil
        chosenLyricSource = nil'''
new='''        let restored = SongMetadata.editorLyricsState(text: song.lyrics, timedTTML: song.syncedLyricsTTML)
        lyrics = restored.text
        chosenTTML = restored.ttml
        chosenLyricText = restored.ttml != nil ? restored.text : nil
        chosenLyricSource = restored.ttml != nil ? (song.syncedLyricsSource ?? "saved-ttml") : nil'''
assert s.count(old)==1;s=s.replace(old,new,1)
s=s.replace('chosenTTML != nil ? "timed" : (SongMetadata.isSyncedLRC(lyrics) ? "line" : "plain")','SongMetadata.editorLyricsState(text: lyrics, timedTTML: chosenTTML).timing',1)
p.write_text(s)
p=r/'iDeviceManager.swift';d=p.read_text()
old='        customAlbumBackgroundColor expectedColor: String? = nil\n    ) -> Bool {'
new='        customAlbumBackgroundColor expectedColor: String? = nil,\n        lyrics expectedLyrics: String? = nil,\n        timedLyrics expectedTimedLyrics: Bool? = nil\n    ) -> Bool {'
assert d.count(old)==1;d=d.replace(old,new,1)
marker='            var colorMatches = true'
verify=r'''            var lyricMatches = true
            if let expectedLyrics, let expectedTimedLyrics {
                let actual = self.firstStringQuery(db: db, sql: "SELECT lyrics FROM lyrics WHERE item_pid = ? LIMIT 1", itemPid: itemPid)
                let flag = self.firstStringQuery(db: db, sql: "SELECT CAST(time_synced_lyrics_available AS TEXT) FROM lyrics WHERE item_pid = ? LIMIT 1", itemPid: itemPid)
                lyricMatches = actual == expectedLyrics && flag == (expectedTimedLyrics ? "1" : "0")
                Logger.shared.log("[LyricSave] payload and timing flag readback verified=\(lyricMatches) itemPid=\(itemPid)")
            }

'''
assert marker in d;d=d.replace(marker,verify+marker,1)
d=d.replace('                colorMatches && actualTitle == expectedTitle &&','                lyricMatches && colorMatches && actualTitle == expectedTitle &&',1)
start=d.index('    func updateExportableSongMetadata(');end=d.index('\n    func ',start+10)
segment=d[start:end]
old='customAlbumBackgroundColor: updatedSong.customAlbumBackgroundColor\n'
new='customAlbumBackgroundColor: updatedSong.customAlbumBackgroundColor,\n                lyrics: lyricPayload.text, timedLyrics: lyricPayload.timed\n'
assert segment.count(old)==2;segment=segment.replace(old,new);d=d[:start]+segment+d[end:];p.write_text(d)
p=r/'LyricsSearchSheet.swift';s=p.read_text().replace('self.errorMessage = nil\n                }','self.errorMessage = "\\(service.displayName) returned no matches or could not be reached. Try another query or service."\n                }',1);p.write_text(s)
print('Restored TTML editor round trip, decimal times, and independent LyricsPlus catalog search')
PY
