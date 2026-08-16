#!/usr/bin/env bash
set -euo pipefail

TARGET="ByeTunes/MusicManager/ManageBackupsView.swift"

test -f "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
import textwrap

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = "FILZA_MANAGE_BACKUPS_TYPECHECK_SPLIT"
if marker in text:
    print("ByeTunes ManageBackupsView type-check split already applied")
    raise SystemExit(0)

body_decl = "    var body: some View {\n"
zstack_start_marker = "        ZStack {\n"
nav_marker = '        .navigationTitle("Manage Backups")\n'
db_marker = '                    VStack(alignment: .leading, spacing: 8) {\n                        Text("DATABASE SNAPSHOTS")\n'
playlist_marker = '                    VStack(alignment: .leading, spacing: 8) {\n                        Text("PLAYLIST BACKUPS")\n'
outer_vstack_close = "                }\n                .padding(16)\n"

for required in (body_decl, zstack_start_marker, nav_marker, db_marker, playlist_marker, outer_vstack_close):
    if required not in text:
        raise SystemExit(f"ManageBackupsView compatibility split: expected source marker missing: {required!r}")

body_pos = text.index(body_decl)
zstack_pos = body_pos + len(body_decl)
if not text.startswith(zstack_start_marker, zstack_pos):
    raise SystemExit("ManageBackupsView compatibility split: body no longer begins with expected ZStack")

nav_pos = text.index(nav_marker, zstack_pos)
zblock = text[zstack_pos:nav_pos]

db_pos = zblock.index(db_marker)
playlist_pos = zblock.index(playlist_marker, db_pos)
playlist_end = zblock.index(outer_vstack_close, playlist_pos)

# Keep the exact original section source. Only move each section into a
# separate opaque SwiftUI expression so Swift's constraint solver does not
# have to solve the entire screen as one expression.
db_block = zblock[db_pos:playlist_pos].rstrip() + "\n"
playlist_block = zblock[playlist_pos:playlist_end].rstrip() + "\n"

# Prove key user-visible/action statements are present before moving them.
required_db = [
    'Text("DATABASE SNAPSHOTS")',
    'restoreSnapshot(named: snap.folderName)',
    'snapshotPendingDeletion = snap',
    'showingRenameAlert = true',
]
required_playlist = [
    'Text("PLAYLIST BACKUPS")',
    'restorePlaylist(from: backup.fileURL)',
    'ShareSheetHelper.share(items: [backup.fileURL])',
    'playlistBackupPendingDeletion = backup',
]
for token in required_db:
    if token not in db_block:
        raise SystemExit(f"ManageBackupsView compatibility split: database token missing: {token}")
for token in required_playlist:
    if token not in playlist_block:
        raise SystemExit(f"ManageBackupsView compatibility split: playlist token missing: {token}")

compact_zblock = (
    zblock[:db_pos]
    + "                    databaseSnapshotsSection\n\n"
    + "                    playlistBackupsSection\n"
    + zblock[playlist_end:]
)

# Convert the original section indentation (20 spaces at the outer VStack) to
# the normal 8-space indentation inside each computed property.
def property_body(block: str) -> str:
    return textwrap.indent(textwrap.dedent(block).rstrip() + "\n", "        ")

helpers = (
    f"    // {marker}: compiler-only expression split; source statements unchanged.\n"
    "    @ViewBuilder\n"
    "    private var databaseSnapshotsSection: some View {\n"
    + property_body(db_block)
    + "    }\n\n"
    "    @ViewBuilder\n"
    "    private var playlistBackupsSection: some View {\n"
    + property_body(playlist_block)
    + "    }\n\n"
    "    private var backupsContent: some View {\n"
    + compact_zblock
    + "    }\n\n"
)

new_body_prefix = body_decl + "        backupsContent\n"
text = text[:body_pos] + helpers + new_body_prefix + text[nav_pos:]

# Postconditions: all original behavior markers and every downstream modifier
# remain in place, while body now starts from the opaque backupsContent value.
postconditions = [
    marker,
    "private var databaseSnapshotsSection: some View",
    "private var playlistBackupsSection: some View",
    "private var backupsContent: some View",
    "var body: some View {\n        backupsContent",
    '.navigationTitle("Manage Backups")',
    '.sheet(isPresented: $showingImportPicker)',
    '.alert("Delete Database Backup?"',
    '.alert("Rename Backup"',
    '.alert("Delete Playlist Backup?"',
    '.alert("Restore Playlist"',
    "if showToast {",
    "snapshotProgressPopup",
]
for token in postconditions:
    if token not in text:
        raise SystemExit(f"ManageBackupsView compatibility split postcondition failed: {token}")

path.write_text(text, encoding="utf-8")
print("Applied compiler-only ManageBackupsView expression split; UI/actions preserved")
PY
