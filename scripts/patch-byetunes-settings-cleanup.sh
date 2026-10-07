#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
p=root/"SettingsView.swift"
s=p.read_text()

def block_end(text,start):
    brace=text.index("{",start)
    depth=0; quoted=False; escaped=False
    for i in range(brace,len(text)):
        c=text[i]
        if quoted:
            if escaped: escaped=False
            elif c=="\\": escaped=True
            elif c=='"': quoted=False
            continue
        if c=='"': quoted=True
        elif c=="{": depth+=1
        elif c=="}":
            depth-=1
            if depth==0: return i+1
    raise SystemExit("unbalanced settings section")

for title in ["SUPPORT","CREDITS"]:
    marker=f'Text("{title}")'
    if marker in s:
        start=s.rfind("                VStack(alignment: .leading, spacing: 12) {",0,s.index(marker))
        if start<0: raise SystemExit(f"{title} section anchor missing")
        s=s[:start]+s[block_end(s,start):]

if 'Text("Version")' in s:
    start=s.rfind("                        HStack {",0,s.index('Text("Version")'))
    end=block_end(s,start)
    music=s.index('Text("Music Formats")',end)
    nextrow=s.rfind("                        HStack {",end,music)
    if start<0 or nextrow<0: raise SystemExit("version row anchors missing")
    s=s[:start]+s[nextrow:]

marker='                        Toggle(isOn: $keepLocalMetadataForLocalFiles) {'
if marker in s:
    start=s.rfind("                        Divider().padding(.leading, 56)",0,s.index(marker))
    end=s.index('                        if metadataSource != "apple" {',s.index(marker))
    s=s[:start]+s[end:]

s=s.replace("Apple Music Subscription Lyrics","Apple Synced Lyrics")
s=s.replace(
    "If you have an active Apple Music subscription, use Apple's own time-synced lyrics instead of the community sources above. Requires an internet connection.",
    "Use Music.app's native time-synced lyrics for Apple-catalog-matched tracks. Requires an internet connection."
)
p.write_text(s)

music=root/"MusicView.swift"
ms=music.read_text().replace(
    'if !UserDefaults.standard.bool(forKey: "keepLocalMetadataForLocalFiles") {',
    'if (UserDefaults.standard.string(forKey: "metadataSource") ?? "apple") != "local" {'
)
music.write_text(ms)

metadata=root/"SongMetadata.swift"
ss=metadata.read_text().replace(
    'let autofetch = UserDefaults.standard.bool(forKey: "autofetchMetadata")',
    'let autofetch = (UserDefaults.standard.object(forKey: "autofetchMetadata") as? Bool) ?? true'
)
metadata.write_text(ss)
print("Preserved upstream lyric services and native Apple synced lyric mode")
PY
grep -Fq 'Text("Fetch Lyrics")' "$ROOT/SettingsView.swift"
grep -Fq 'Text("Apple Synced Lyrics")' "$ROOT/SettingsView.swift"
grep -Fq 'Replay Onboarding' "$ROOT/SettingsView.swift"
! grep -Fq 'Apple Music Subscription Lyrics' "$ROOT/SettingsView.swift"
! grep -Fq 'showingPairingPicker' "$ROOT/SettingsView.swift"
