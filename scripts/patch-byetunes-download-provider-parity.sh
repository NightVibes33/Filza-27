#!/usr/bin/env bash
set -euo pipefail

# Historical hook retained for Makefile compatibility. Download-search provider
# behavior now stays on the exact pinned ByeTunes v2.4 implementation instead
# of adding reconstructed YouTube/All Sources routes.

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
DOWNLOAD="ByeTunes/MusicManager/DownloadView.swift"

test -f "$SETTINGS"
test -f "$DOWNLOAD"

python3 - "$SETTINGS" "$DOWNLOAD" <<'PY'
from pathlib import Path
import sys
settings, download = map(Path, sys.argv[1:])
ss = settings.read_text()
dv = download.read_text()

start = ss.find('private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {')
if start < 0:
    raise SystemExit('upstream DownloadSearchProviderOption not found')
end = ss.find('\n}\n', start)
block = ss[start:end]
if 'case all' in block or 'case youtube' in block:
    raise SystemExit('non-upstream download provider still injected in Settings')

start = dv.find('    enum SearchProvider: String, CaseIterable, Identifiable {')
if start < 0:
    raise SystemExit('upstream DownloadView.SearchProvider not found')
end = dv.find('\n    }', start)
block = dv[start:end]
if 'case youtube' in block:
    raise SystemExit('non-upstream YouTube download provider still injected')
PY

echo "Verified upstream ByeTunes v2.4 download-provider behavior"
