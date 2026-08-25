#!/usr/bin/env bash
set -euo pipefail

SCRIPT='scripts/temp-reapply-3105.sh'
python3 - "$SCRIPT" <<'PYCODE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding='utf-8')
start_token = 'MAIN_ICON="$(mktemp)"\n'
end_token = 'rm -f "$MAIN_ICON"\n'
start = t.find(start_token)
if start < 0:
    raise SystemExit('temporary icon bridge start block not found')
end = t.find(end_token, start)
if end < 0:
    raise SystemExit('temporary icon bridge end block not found')
end += len(end_token)
replacement = '''# Seed only the integration marker on the latest upstream implementation.
# scripts/patch-3105-icon-performance.sh owns the complete current Filza bridge
# and replaces everything after this marker later in the integration sequence.
printf '\\n#pragma mark - Filza shared paired SpringBoard icon service\\n' >> "$SOURCES/AppIconHelper.m"
'''
p.write_text(t[:start] + replacement + t[end:], encoding='utf-8')
PYCODE

exec bash "$SCRIPT"
