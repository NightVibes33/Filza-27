#!/usr/bin/env bash
set -euo pipefail
bash scripts/patch-airlift-books-snapshot.sh
python3 - <<'PY'
from pathlib import Path
p=Path('Makefile');s=p.read_text();needle='FilzaApplySandboxExt_FILES = ';i=s.index(needle);e=s.index('\n',i);line=s[i:e]
for f in ('AirliftBooksState.m','AirliftCanaryExploit.m'):
    if f not in line: line += ' ' + f
p.write_text(s[:i]+line+s[e:])
PY
