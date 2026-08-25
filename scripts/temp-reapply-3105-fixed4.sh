#!/usr/bin/env bash
set -euo pipefail

SCRIPT='scripts/temp-reapply-3105.sh'
python3 - "$SCRIPT" <<'PYCODE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding='utf-8')

# Latest upstream AppIconHelper remains the base; the existing Filza icon patch
# generates the shared SpringBoardServices suffix later.
start_token = 'MAIN_ICON="$(mktemp)"\n'
end_token = 'rm -f "$MAIN_ICON"\n'
start = t.find(start_token)
if start < 0:
    raise SystemExit('temporary icon bridge start block not found')
end = t.find(end_token, start)
if end < 0:
    raise SystemExit('temporary icon bridge end block not found')
end += len(end_token)
t = t[:start] + '''# Seed only the integration marker on the latest upstream implementation.\nprintf '\\n#pragma mark - Filza shared paired SpringBoard icon service\\n' >> "$SOURCES/AppIconHelper.m"\n''' + t[end:]

# Main stores this runtime pairing fix as a build-time patch.
anchor = 'bash scripts/patch-3105-icon-performance.sh\n'
if anchor not in t:
    raise SystemExit('icon-performance patch anchor not found')
t = t.replace(anchor, anchor + 'bash scripts/patch-3105-pairing-importer.sh\n', 1)

# The Actions token cannot push commits that alter workflow YAML. Keep the
# integration commit code-only by restoring workflows from its parent after the
# script creates the commit; workflow cleanup/updates are done separately by the
# authenticated GitHub connection.
push = 'git push origin HEAD:temp-3105-pristine-rebase\n'
if push not in t:
    raise SystemExit('final integration push anchor not found')
replacement = '''git checkout HEAD^ -- .github/workflows\ngit add .github/workflows\ngit commit --amend --no-edit\ngit push origin HEAD:temp-3105-pristine-rebase\n'''
t = t.replace(push, replacement, 1)

p.write_text(t, encoding='utf-8')
PYCODE

exec bash "$SCRIPT"
