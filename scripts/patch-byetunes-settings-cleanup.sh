#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'SettingsView.swift'
s = p.read_text()
def block_end(text, start):
    brace = text.index('{', start)
    depth, quoted, escaped = 0, False, False
    for i in range(brace, len(text)):
        c = text[i]
        if quoted:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': quoted = False
        elif c == '"': quoted = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i + 1
    raise SystemExit('Unbalanced settings section')
for title in ['SUPPORT', 'CREDITS']:
    marker = f'Text("{title}")'
    if marker not in s: continue
    start = s.rfind('                VStack(alignment: .leading, spacing: 12) {', 0, s.index(marker))
    if start < 0: raise SystemExit(f'{title} section anchor missing')
    s = s[:start] + s[block_end(s, start):]
if 'Text("Version")' in s:
    start = s.rfind('                        HStack {', 0, s.index('Text("Version")'))
    end = block_end(s, start)
    music = s.index('Text("Music Formats")', end)
    next_row = s.rfind('                        HStack {', end, music)
    if start < 0 or next_row < 0: raise SystemExit('About version row anchors missing')
    s = s[:start] + s[next_row:]
for marker in ['Text("Music Formats")', 'Text("Ringtone Formats")']:
    if marker not in s: raise SystemExit(f'Preserved row missing: {marker}')
# This host has no Download tab; keep only metadata settings.
start = s.find('                    Text("DOWNLOADS")')
if start >= 0:
    end = s.index('                    }\n                    .frame(width: max(proxy.size.width', start)
    s = s[:start] + s[end:]
s = s.replace('Metadata & Downloads', 'Metadata').replace('Text("Metadata & Lyrics")', 'Text("Metadata")')
# Local Files is already a source option. A separate persisted override could
# silently disable the online provider selected by the user.
marker = '                        Toggle(isOn: $keepLocalMetadataForLocalFiles) {'
if marker in s:
    start = s.rfind('                        Divider().padding(.leading, 56)', 0, s.index(marker))
    end = s.index('                        if metadataSource != "apple" {', s.index(marker))
    s = s[:start] + s[end:]
p.write_text(s)

music = root / 'MusicView.swift'
ms = music.read_text()
ms = ms.replace('if !UserDefaults.standard.bool(forKey: "keepLocalMetadataForLocalFiles") {', 'if (UserDefaults.standard.string(forKey: "metadataSource") ?? "apple") != "local" {')
music.write_text(ms)
metadata = root / 'SongMetadata.swift'
ss = metadata.read_text()
ss = ss.replace('let autofetch = UserDefaults.standard.bool(forKey: "autofetchMetadata")', 'let autofetch = (UserDefaults.standard.object(forKey: "autofetchMetadata") as? Bool) ?? true')
metadata.write_text(ss)

# File import must reset the old connection just as the on-device pairing
# sheet does; otherwise startHeartbeat can reuse or skip an existing attempt.
for name in ['SettingsView.swift', 'OnboardingView.swift']:
    p = root / name
    s = p.read_text()
    start = s.index('    func handlePairingImport(url: URL?) {')
    end = block_end(s, start)
    function = s[start:end]
    anchor = '        guard let url = url else { return }\n'
    if 'manager.setAutoReconnectSuspended(true)' not in function:
        if function.count(anchor) != 1: raise SystemExit(f'{name}: import guard missing')
        function = function.replace(anchor, anchor + '\n        manager.setAutoReconnectSuspended(true)\n        defer { manager.setAutoReconnectSuspended(false) }\n', 1)
    function = function.replace('manager.startHeartbeat()', 'manager.startHeartbeat(forceReconnect: true)')
    function = function.replace('manager.startHeartbeat { success in', 'manager.startHeartbeat(forceReconnect: true) { success in')
    p.write_text(s[:start] + function + s[end:])
print('Removed Support, Credits, and About version; file import starts a fresh connection')
PY
