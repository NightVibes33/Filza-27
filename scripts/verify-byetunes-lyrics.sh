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
blocks=[]
for name in methods:
    marker=f'    static func {name}('
    if marker not in source: marker=f'    private static func {name}('
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
Path(sys.argv[2]).write_text('import Foundation\nimport FoundationXML\nstruct SongMetadata {\n'+'\n'.join(blocks)+'\n}\n'+tests)
PY
swift -swift-version 5 "$TEST_SOURCE"
