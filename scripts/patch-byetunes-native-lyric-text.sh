#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=r/'SongMetadata.swift';s=p.read_text()
if 'static func nativeLibraryLyricsPayload(' in s:sys.exit(0)
helper=r'''
    // The native library's lyrics field is display text, not a TTML document loader.
    static func nativeLibraryLyricsPayload(text: String?, timedTTML: String?, durationMs: Int) -> (text: String, timed: Bool) {
        _ = durationMs
        let state = editorLyricsState(text: text, timedTTML: timedTTML)
        return (cleanLyrics(state.text), false)
    }

    static func rememberNativeLyricDocument(for song: SongMetadata) {
        let state = editorLyricsState(text: song.lyrics, timedTTML: song.syncedLyricsTTML)
        let key = "filzaNativeLyricDocument.v1." + song.remoteFilename
        guard let document = state.ttml else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set([
            "text": cleanLyrics(state.text), "ttml": document,
            "source": song.syncedLyricsSource ?? "saved-ttml", "timing": state.timing
        ], forKey: key)
    }

    static func restoreNativeLyricDocument(to song: inout SongMetadata) {
        let key = "filzaNativeLyricDocument.v1." + song.remoteFilename
        guard let cached = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              cached["text"] == cleanLyrics(song.lyrics ?? ""), let document = cached["ttml"],
              isValidCustomTTML(document), plainTextFromTTML(document) != nil else { return }
        song.syncedLyricsTTML = document
        song.syncedLyricsSource = cached["source"]
        song.syncedLyricsTiming = cached["timing"]
    }
'''
s=s.replace('    static func editorLyricsState(',helper+'\n    static func editorLyricsState(',1);p.write_text(s)
p=r/'MediaLibraryBuilder.swift';s=p.read_text();assert s.count('SongMetadata.libraryLyricsPayload(')==1
s=s.replace('SongMetadata.libraryLyricsPayload(','SongMetadata.nativeLibraryLyricsPayload(',1)
s=s.replace('            let lyricPayload = SongMetadata.nativeLibraryLyricsPayload(','            SongMetadata.rememberNativeLyricDocument(for: song)\n            let lyricPayload = SongMetadata.nativeLibraryLyricsPayload(',1);p.write_text(s)
p=r/'iDeviceManager.swift';s=p.read_text();assert s.count('SongMetadata.libraryLyricsPayload(')==1
s=s.replace('SongMetadata.libraryLyricsPayload(','SongMetadata.nativeLibraryLyricsPayload(',1)
anchor='            completion(true, "Saved and verified metadata for \\(safeTitle).")'
assert s.count(anchor)==1;s=s.replace(anchor,'            SongMetadata.rememberNativeLyricDocument(for: updatedSong)\n'+anchor,1);p.write_text(s)
p=r/'DeviceLibraryBrowserView.swift';s=p.read_text();anchor='        editingDraftSong.lyrics = song.lyrics\n';assert s.count(anchor)==1;s=s.replace(anchor,anchor+'        SongMetadata.restoreNativeLyricDocument(to: &editingDraftSong)\n',1);p.write_text(s)
print('Native Music receives paragraph-separated text; original timed documents retained locally')
PY
