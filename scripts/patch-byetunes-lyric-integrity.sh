#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def replace_once(s, old, new, label):
    if new in s: return s
    if s.count(old) != 1: raise SystemExit(f'{label}: expected one anchor, got {s.count(old)}')
    return s.replace(old, new, 1)
def replace_function(s, signature, replacement):
    start = s.index(signature)
    end = s.index('\n    }', start) + len('\n    }')
    return s[:start] + replacement + s[end:]
p = root/'SongMetadata.swift';s=p.read_text()
s = replace_function(s, '    static func cleanLyrics(', r'''    static func cleanLyrics(_ rawLyrics: String, title: String? = nil, artist: String? = nil) -> String {
        // A title can also be an actual lyric. Never delete a line by its words.
        _ = title
        _ = artist
        let normalized = rawLyrics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
        return isSyncedLRC(normalized)
            ? plainTextFromLRC(normalized)
            : normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }''')
s = replace_once(s, '            guard !lyric.isEmpty else { continue }\n', '            // Empty timed cues end the preceding lyric during instrumental gaps.\n', 'retain empty LRC cues')
s = replace_once(s, '        guard !lines.isEmpty else { return nil }\n', '        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }\n', 'require lyric content')
s = replace_once(s, '            let line = lines[index]\n            let next =', '            let line = lines[index]\n            guard !line.text.isEmpty else { continue }\n            let next =', 'skip rendering empty cues')
s = replace_function(s, '    static func plainTextFromLRC(', r'''    static func plainTextFromLRC(_ source: String) -> String {
        let timestampPattern = #"^\s*(?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\]\s*)+"#
        let metadataPattern = #"^\s*\[(?:ar|ti|al|by|offset|re|ve|length):[^\]]*\]\s*$"#
        let metadataRegex = try? NSRegularExpression(pattern: metadataPattern, options: [.caseInsensitive])
        return source.components(separatedBy: .newlines).compactMap { raw -> String? in
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            if metadataRegex?.firstMatch(in: raw, range: range) != nil { return nil }
            return raw.replacingOccurrences(of: timestampPattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }''')
s = replace_function(s, '    private static func formatTTMLTime(', r'''    private static func formatTTMLTime(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d",
                      milliseconds / 3_600_000,
                      (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60,
                      milliseconds % 1000)
    }''')
s = replace_function(s, '    static func normalizeCustomTTML(', r'''    static func normalizeCustomTTML(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Normalize legacy mm:ss attributes without changing their timing.
        let pattern = #"(begin|end)="([0-9]{1,3}):([0-9]{2}(?:\.[0-9]+)?)""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            for match in matches.reversed() {
                guard let attr = Range(match.range(at: 1), in: text),
                      let minute = Range(match.range(at: 2), in: text),
                      let second = Range(match.range(at: 3), in: text),
                      let range = Range(match.range, in: text),
                      let minutes = Double(text[minute]), let seconds = Double(text[second]) else { continue }
                let replacement = "\(text[attr])=\"\(formatTTMLTime(minutes * 60 + seconds))\""
                text.replaceSubrange(range, with: replacement)
            }
        }
        return text
    }''')
helper=r'''    static func libraryLyricsPayload(text: String?, timedTTML: String?, durationMs: Int) -> (text: String, timed: Bool) {
        if let timedTTML, isValidCustomTTML(timedTTML) {
            return (normalizeCustomTTML(timedTTML), true)
        }
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidCustomTTML(raw) { return (normalizeCustomTTML(raw), true) }
        if let converted = customTTMLFromLRC(raw, durationMs: durationMs) {
            return (converted, true)
        }
        return (cleanLyrics(raw), false)
    }

'''
if 'static func libraryLyricsPayload(' not in s:
    anchor='    static func customTTMLFromLRC('
    pos=s.index(anchor);s=s[:pos]+helper+s[pos:]
p.write_text(s)
p=root/'MediaLibraryBuilder.swift';s=p.read_text()
old='''            let fallbackTimedTTML = SongMetadata.customTTMLFromLRC(song.lyrics ?? "", durationMs: song.durationMs)
            let customTimedTTML = song.syncedLyricsTTML ?? fallbackTimedTTML
            let hasCustomTimedLyrics = customTimedTTML != nil
            let resolvedLyricsText = customTimedTTML
                ?? SongMetadata.cleanLyrics(song.lyrics ?? "", title: song.title, artist: song.artist)'''
new='''            let lyricPayload = SongMetadata.libraryLyricsPayload(
                text: song.lyrics, timedTTML: song.syncedLyricsTTML, durationMs: song.durationMs)
            let hasCustomTimedLyrics = lyricPayload.timed
            let resolvedLyricsText = lyricPayload.text'''
s=replace_once(s,old,new,'new import lyric payload');p.write_text(s)
p=root/'iDeviceManager.swift';s=p.read_text()
old='''            let escapedLyrics = self.escapeSQLString((updatedSong.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines))'''
new='''            let lyricPayload = SongMetadata.libraryLyricsPayload(
                text: updatedSong.lyrics, timedTTML: updatedSong.syncedLyricsTTML,
                durationMs: updatedSong.durationMs)
            let escapedLyrics = self.escapeSQLString(lyricPayload.text)
            let timedLyricsAvailable = lyricPayload.timed ? 1 : 0'''
s=replace_once(s,old,new,'metadata edit lyric payload')
s=replace_once(s,"VALUES (\\(itemPid), '\\(escapedLyrics)', 1, 1)","VALUES (\\(itemPid), '\\(escapedLyrics)', 0, \\(timedLyricsAvailable))",'metadata edit flags');p.write_text(s)
p=root/'ManualMetadataEditor.swift';s=p.read_text()
anchor='        updatedSong.lyrics = lyrics.isEmpty ? nil : lyrics\n'
replacement=anchor+'''        if updatedSong.lyrics != song.lyrics {
            // Edited text must not be overwritten by cached timing from an older lyric.
            updatedSong.syncedLyricsTTML = nil
            updatedSong.syncedLyricsSource = nil
            updatedSong.syncedLyricsTiming = nil
        }
'''
s=replace_once(s,anchor,replacement,'invalidate cached lyrics after edits');p.write_text(s)
print('Applied consistent lyric writes, lossless text cleanup, and TTML clock timing')
PY
