#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
TEST_SOURCE="$(mktemp "${TMPDIR:-/tmp}/byetunes-color.XXXXXX")"
trap 'rm -f "$TEST_SOURCE"' EXIT
python3 - "$ROOT" "$TEST_SOURCE" <<'PY'
from pathlib import Path
import sys,sqlite3
r=Path(sys.argv[1]);s=(r/'MediaLibraryBuilder.swift').read_text();blocks=[]
for name in ['customAlbumColorAnalysisJSON','rgbColor','relativeLuminance','mix','hexColor','clampColor']:
 marker=f'    static func {name}('
 if marker not in s:marker=f'    private static func {name}('
 start=s.index(marker);end=s.index('\n    }',start)+len('\n    }');blocks.append(s[start:end])
tests=r'''
for hex in ["#123456", "#FFFFFF", "#000000"] {
    let data = Data(MediaLibraryBuilder.customAlbumColorAnalysisJSON(hex: hex)!.utf8)
    let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let analysis = object["ColorAnalysis"] as! [String: Any]
    let palette = analysis["1"] as! [String: String]
    precondition(palette["backgroundColor"] == hex)
}
precondition(MediaLibraryBuilder.customAlbumColorAnalysisJSON(hex: "not-a-color") == nil)
print("PASS: custom album palette JSON and invalid color rejection")
'''
Path(sys.argv[2]).write_text('import Foundation\nstruct MediaLibraryBuilder {\n'+'\n'.join(blocks)+'\n}\n'+tests)
# Exercise the exact update statement emitted into the device save path.
d=(r/'iDeviceManager.swift').read_text();start=d.index('UPDATE artwork SET interest_data');end=d.index('\n                    """',start)
sql=d[start:end].replace('\\(escaped)','custom-palette').replace('\\(itemPid)','10').replace('\\(newAlbumPid)','20')
db=sqlite3.connect(':memory:');db.executescript('CREATE TABLE artwork(artwork_token TEXT,interest_data TEXT); CREATE TABLE artwork_token(artwork_token TEXT,entity_pid INTEGER,entity_type INTEGER); INSERT INTO artwork VALUES ("song","old"),("album","old"),("other","old"); INSERT INTO artwork_token VALUES ("song",10,0),("album",20,1),("other",30,0);')
db.execute(sql)
assert db.execute('SELECT * FROM artwork ORDER BY artwork_token').fetchall()==[('album','custom-palette'),('other','old'),('song','custom-palette')]
assert 'customAlbumBackgroundColor: updatedSong.customAlbumBackgroundColor' in d
assert '[AlbumColorSave] device readback verified=' in d
print('PASS: color-only artwork update, album linkage, unrelated artwork isolation and readback wiring')
PY
swift -swift-version 5 "$TEST_SOURCE"
