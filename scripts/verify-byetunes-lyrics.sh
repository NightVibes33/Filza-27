#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
TEST_SOURCE="$(mktemp "${TMPDIR:-/tmp}/byetunes-lyrics.XXXXXX")"
trap 'rm -f "$TEST_SOURCE"' EXIT
python3 - "$ROOT/SongMetadata.swift" "$TEST_SOURCE" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
methods=['cleanLyrics','plainTextFromLRC','normalizeCustomTTML','isValidCustomTTML','isSyncedLRC','libraryLyricsPayload','customTTMLFromLRC','formatTTMLTime','escapeTTMLText']
if 'static func parsePublicWordLyrics(' in source:
    methods += ['parsePublicWordLyrics', 'lyricIdentity']
blocks=[]
for name in methods:
    marker=f'    static func {name}('
    if marker not in source: marker=f'    private static func {name}('
    start=source.index(marker);end=source.index('\n    }',start)+len('\n    }')
    blocks.append(source[start:end])
if 'static func plainTextFromTTML(' in source:
    for marker in ['    static func plainTextFromTTML(', '    private final class AMLLTextParser:']:
        start=source.index(marker);end=source.index('\n    }',start)+len('\n    }')
        blocks.append(source[start:end])
tests=r'''
let lrc = "[00:20.13] Stay\n[00:24.46] It's [still] you & me\n[00:29.06]\n[00:33.21] Stay"
let payload = SongMetadata.libraryLyricsPayload(text: lrc, timedTTML: nil, durationMs: 40000)
precondition(payload.timed)
precondition(payload.text.contains("begin=\"00:00:20.130\""))
precondition(payload.text.contains("end=\"00:00:29.060\""))
precondition(payload.text.contains("It&apos;s [still] you &amp; me"))
precondition(XMLParser(data: Data(payload.text.utf8)).parse())
let plain = SongMetadata.cleanLyrics(lrc, title: "Stay", artist: "Test")
precondition(plain == "Stay\nIt's [still] you & me\n\nStay")
precondition(SongMetadata.cleanLyrics("Stay\n[Chorus]\nStay", title: "Stay") == "Stay\n[Chorus]\nStay")
let untimed = SongMetadata.libraryLyricsPayload(text: "Stay", timedTTML: nil, durationMs: 40000)
precondition(!untimed.timed && untimed.text == "Stay")
let empty = SongMetadata.libraryLyricsPayload(text: nil, timedTTML: nil, durationMs: 40000)
precondition(!empty.timed && empty.text.isEmpty)
let legacy = payload.text.replacingOccurrences(of: "00:00:20.130", with: "0:20.130")
let normalized = SongMetadata.libraryLyricsPayload(text: legacy, timedTTML: nil, durationMs: 40000)
precondition(normalized.timed && normalized.text == payload.text)
let repeated = SongMetadata.customTTMLFromLRC("[00:01.00][00:03.00] Stay", durationMs: 4000)!
precondition(repeated.contains("begin=\"00:00:01.000\""))
precondition(repeated.contains("begin=\"00:00:03.000\""))
print("PASS: timed save payloads, TTML XML/clock times, silent gaps, repeats, Unicode-safe text, and plain/empty flags")
'''
if 'static func plainTextFromTTML(' in source:
    tests += r'''
let rich = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"00:01.000\" end=\"00:03.000\"><span begin=\"00:01.000\" end=\"00:02.000\">Stay </span><span begin=\"00:02.000\" end=\"00:03.000\">[here] &amp; sing</span></p><p begin=\"00:04.000\" end=\"00:05.000\">Again</p></div></body></tt>"
precondition(SongMetadata.plainTextFromTTML(rich) == "Stay [here] & sing\nAgain")
precondition(SongMetadata.plainTextFromTTML("<tt><body>") == nil)
precondition(SongMetadata.libraryLyricsPayload(text: "Stay [here] & sing\nAgain", timedTTML: rich, durationMs: 5000).text == rich)
print("PASS: AMLL text extraction and preservation of selected word-timed TTML")
'''
if 'static func parsePublicWordLyrics(' in source:
    tests += r'''
let fixture = Data(#"{"type":"Word","processingTime":{"selectedSongMetadata":{"title":"Stay","artist":"Test","duration":4}},"lyrics":[{"time":1000,"duration":2000,"syllabus":[{"time":1000,"duration":1000,"text":"Stay "},{"time":2000,"duration":1000,"text":"& sing"}]}]}"#.utf8)
let wordDocument = SongMetadata.parsePublicWordLyrics(data: fixture, title: "Stay", artist: "Test", durationMs: 4000)!
precondition(wordDocument.timing == "word")
precondition(SongMetadata.plainTextFromTTML(wordDocument.ttml) == "Stay & sing")
precondition(wordDocument.ttml.contains("begin=\"00:00:02.000\""))
precondition(SongMetadata.parsePublicWordLyrics(data: fixture, title: "Stay (Live)", artist: "Test", durationMs: 4000) == nil)
precondition(SongMetadata.parsePublicWordLyrics(data: fixture, title: "Stay", artist: "Cover Artist", durationMs: 4000) == nil)
precondition(SongMetadata.parsePublicWordLyrics(data: fixture, title: "Stay", artist: "Test", durationMs: 8000) == nil)
precondition(SongMetadata.parsePublicWordLyrics(data: Data("{}".utf8), title: "Stay", artist: "Test", durationMs: 4000) == nil)
print("PASS: public word timing, whitespace, recording identity, duration and malformed response rejection")
'''
Path(sys.argv[2]).write_text('import Foundation\n#if canImport(FoundationXML)\nimport FoundationXML\n#endif\nstruct SongMetadata {\n'+'\n'.join(blocks)+'\n}\n'+tests)
PY
swift -swift-version 5 "$TEST_SOURCE"
