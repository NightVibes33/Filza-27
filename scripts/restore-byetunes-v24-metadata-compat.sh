#!/bin/bash
set -euo pipefail

# Metadata/search is intentionally kept on the exact pinned ByeTunes v2.4
# implementation (8a4be32f188f30b98f15b00566c5ff3edc1c03b1).
# This script is retained because the Makefile calls it in the historical build
# order, but it no longer rewrites MusicView, Settings, the manual editor, or
# background metadata behavior.

MUSIC="ByeTunes/MusicManager/MusicView.swift"
SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MANUAL="ByeTunes/MusicManager/ManualMetadataEditor.swift"
SEARCH_SHEET="ByeTunes/MusicManager/iTunesSearchSheet.swift"
BACKGROUND="ByeTunes/MusicManager/BackgroundMetadataFetchManager.swift"
NETWORK="ByeTunes/MusicManager/MetadataBackgroundURLSession.swift"

for path in "$MUSIC" "$SETTINGS" "$MANUAL" "$SEARCH_SHEET" "$BACKGROUND" "$NETWORK"; do
    test -f "$path"
done

python3 - "$MUSIC" "$SETTINGS" "$SEARCH_SHEET" "$BACKGROUND" "$NETWORK" <<'PY'
from pathlib import Path
import sys

music, settings, search_sheet, background, network = map(Path, sys.argv[1:])
ms = music.read_text()
ss = settings.read_text()
its = search_sheet.read_text()
bg = background.read_text()
nt = network.read_text()

required_music = [
    'let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"',
    'if metadataSource == "apple" && autofetch',
    'else if useiTunes && autofetch',
    'else if metadataSource == "deezer" && autofetch',
    'else if metadataSource == "local" && autofetch',
]
for marker in required_music:
    if marker not in ms:
        raise SystemExit(f"upstream MusicView metadata marker missing: {marker}")

start = ss.find('private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {')
if start < 0:
    raise SystemExit('upstream MetadataSourceOption not found')
end = ss.find('\n}\n', start)
if end < 0:
    raise SystemExit('upstream MetadataSourceOption end not found')
metadata_enum = ss[start:end]
for marker in ('case local', 'case itunes', 'case deezer', 'case apple'):
    if marker not in metadata_enum:
        raise SystemExit(f"upstream metadata source missing: {marker}")
for forbidden in ('case youtube', 'case all'):
    if forbidden in metadata_enum:
        raise SystemExit(f"non-upstream metadata source still injected: {forbidden}")

if 'youtubeResults' in its or 'Button("YouTube")' in its:
    raise SystemExit('non-upstream YouTube manual-search rewrite remains')

if 'let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"' not in bg:
    raise SystemExit('upstream background metadata source selection missing')

if 'return try await URLSession.shared.data(for: request)' not in nt:
    raise SystemExit('upstream foreground URLSession transport missing')
if 'return try await URLSession.shared.data(from: url)' not in nt:
    raise SystemExit('upstream foreground URLSession URL transport missing')
if 'MetadataWebKitRequest' in nt:
    raise SystemExit('non-upstream WebKit metadata transport remains')
PY

echo "Verified exact upstream ByeTunes v2.4 metadata/search behavior (no Filza metadata rewrite applied)"
