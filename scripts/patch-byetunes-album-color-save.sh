#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=r/'MediaLibraryBuilder.swift';s=p.read_text()
if 'static func customAlbumColorAnalysisJSON' not in s:
 start=s.index('        if let customHex = song.customAlbumBackgroundColor,')
 end=s.index('\n        if let appleColors = song.appleMusicArtworkColors,',start)
 block=s[start:end]
 body=block[block.index('            let backgroundLight'):block.rfind('\n        }')]
 helper='''    static func customAlbumColorAnalysisJSON(hex: String) -> String? {
        guard let background = rgbColor(from: hex) else { return nil }
'''+body+'\n    }\n\n'
 s=s[:start]+'''        if let customHex = song.customAlbumBackgroundColor,
           let analysis = customAlbumColorAnalysisJSON(hex: customHex) {
            return analysis
        }
'''+s[end:]
 marker='    private static func colorAnalysisJSON(for song: SongMetadata, version: DatabaseVersion)'
 s=s.replace(marker,helper+marker,1);p.write_text(s)
p=r/'iDeviceManager.swift';s=p.read_text()
if '[AlbumColorSave]' not in s:
 start=s.index('    func updateExportableSongMetadata(');end=s.index('\n    func ',start+10)
 segment=s[start:end]
 segment=segment.replace('            let success = [','            var success = [',1)
 marker='            _ = self.sqliteExec(db, success ? "COMMIT" : "ROLLBACK")'
 color=r'''
            // Apply color-only edits to the existing artwork, inside the same transaction.
            if success, let hex = updatedSong.customAlbumBackgroundColor {
                if let analysis = MediaLibraryBuilder.customAlbumColorAnalysisJSON(hex: hex) {
                    let escaped = self.escapeSQLString(analysis)
                    success = self.sqliteExec(db, """
                    UPDATE artwork SET interest_data = '\(escaped)'
                    WHERE artwork_token IN (
                        SELECT artwork_token FROM artwork_token
                        WHERE (entity_pid = \(itemPid) AND entity_type = 0)
                           OR (entity_pid = \(newAlbumPid) AND entity_type = 1)
                    )
                    """) && sqlite3_changes(db) > 0
                    Logger.shared.log("[AlbumColorSave] artwork color write success=\(success) itemPid=\(itemPid) color=\(hex)")
                } else {
                    success = false
                }
            }

'''
 assert marker in segment;segment=segment.replace(marker,color+marker,1)
 # Extend the existing post-upload verifier: Save succeeds only if the color survives readback.
 segment=segment.replace('explicitRating: explicitRating\n', 'explicitRating: explicitRating,\n                customAlbumBackgroundColor: updatedSong.customAlbumBackgroundColor\n')
 s=s[:start]+segment+s[end:]
 anchor='        explicitRating expectedExplicitRating: Int\n    ) -> Bool {'
 assert anchor in s
 s=s.replace(anchor,'        explicitRating expectedExplicitRating: Int,\n        customAlbumBackgroundColor expectedColor: String? = nil\n    ) -> Bool {',1)
 anchor='            let matches =\n'
 colorcheck=r'''            var colorMatches = true
            if let expectedColor {
                let colorSQL = """
                SELECT ar.interest_data FROM artwork ar
                JOIN artwork_token at ON at.artwork_token = ar.artwork_token
                WHERE at.entity_pid = \(itemPid) AND at.entity_type = 0
                """
                var colorStmt: OpaquePointer?
                colorMatches = false
                if sqlite3_prepare_v2(db, colorSQL, -1, &colorStmt, nil) == SQLITE_OK {
                    while sqlite3_step(colorStmt) == SQLITE_ROW {
                        guard let ptr = sqlite3_column_text(colorStmt, 0),
                              let data = String(cString: ptr).data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let analysis = object["ColorAnalysis"] as? [String: Any],
                              let palette = analysis["1"] as? [String: Any],
                              let actual = palette["backgroundColor"] as? String else { continue }
                        colorMatches = actual.caseInsensitiveCompare(expectedColor) == .orderedSame
                        if colorMatches { break }
                    }
                }
                if colorStmt != nil { sqlite3_finalize(colorStmt) }
                Logger.shared.log("[AlbumColorSave] device readback verified=\(colorMatches) itemPid=\(itemPid)")
            }

'''
 assert anchor in s;s=s.replace(anchor,colorcheck+anchor,1)
 s=s.replace('                actualTitle == expectedTitle &&','                colorMatches && actualTitle == expectedTitle &&',1)
 p.write_text(s)
print('Applied device metadata custom album color write')
PY
