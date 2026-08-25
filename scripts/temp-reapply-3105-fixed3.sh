#!/usr/bin/env bash
set -euo pipefail

SCRIPT='scripts/temp-reapply-3105.sh'
python3 - "$SCRIPT" <<'PYCODE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding='utf-8')

# Use latest upstream AppIconHelper as the base; the existing Filza icon patch
# will generate the shared SpringBoardServices suffix.
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
printf '\\n#pragma mark - Filza shared paired SpringBoard icon service\\n' >> "$SOURCES/AppIconHelper.m"
'''
t = t[:start] + replacement + t[end:]

# Main stores the pairing-importer runtime fix as an explicit build patch, so
# reapply that patch after copying the Filza-owned pairing adapter.
anchor = 'bash scripts/patch-3105-icon-performance.sh\n'
if anchor not in t:
    raise SystemExit('icon-performance patch anchor not found')
t = t.replace(anchor, anchor + 'bash scripts/patch-3105-pairing-importer.sh\n', 1)

p.write_text(t, encoding='utf-8')
PYCODE

exec bash "$SCRIPT"
