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
p.write_text(s)

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
