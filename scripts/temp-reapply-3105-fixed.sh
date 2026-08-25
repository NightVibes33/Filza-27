#!/usr/bin/env bash
set -euo pipefail

SCRIPT='scripts/temp-reapply-3105.sh'
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding='utf-8')
old = '''MAIN_ICON="$(mktemp)"
git show "origin/main:$ROOT/Sources/AppIconHelper.m" > "$MAIN_ICON"
python3 - "$SOURCES/AppIconHelper.m" "$MAIN_ICON" <<'PY'
from pathlib import Path
import sys
current = Path(sys.argv[1])
main = Path(sys.argv[2]).read_text(encoding='utf-8')
text = current.read_text(encoding='utf-8')
marker = '\\n#pragma mark - Filza shared paired SpringBoard icon service\\n'
if marker not in main:
    raise SystemExit('main Filza SpringBoard icon bridge marker missing')
bridge = marker + main.split(marker, 1)[1]
if marker in text:
    text = text.split(marker, 1)[0].rstrip() + '\\n'
current.write_text(text.rstrip() + bridge, encoding='utf-8')
PY
rm -f "$MAIN_ICON"
'''
new = '''# Seed only the integration marker on the latest upstream implementation.
# scripts/patch-3105-icon-performance.sh owns the complete current Filza bridge
# and replaces everything after this marker later in the integration sequence.
printf '\\n#pragma mark - Filza shared paired SpringBoard icon service\\n' >> "$SOURCES/AppIconHelper.m"
'''
if old not in t:
    raise SystemExit('temporary icon bridge block not found')
p.write_text(t.replace(old, new, 1), encoding='utf-8')
PY

exec bash "$SCRIPT"
