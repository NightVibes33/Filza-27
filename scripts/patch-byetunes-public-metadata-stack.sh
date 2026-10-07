#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DOWNLOAD="$ROOT/DownloadView.swift"
CONFIG="$ROOT/Config.swift"
for file in "$DOWNLOAD" "$CONFIG"; do
  test -s "$file" || { echo "missing ByeTunes source: $file" >&2; exit 1; }
done
python3 - "$DOWNLOAD" "$CONFIG" <<'PY'
from pathlib import Path
import sys
download, config = map(Path, sys.argv[1:])

def balanced_end(text, start):
    brace=text.find("{", start)
    if brace < 0: raise SystemExit("opening brace missing")
    depth=0; quoted=False; escaped=False
    for i in range(brace, len(text)):
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
    raise SystemExit("closing brace missing")

def trim(text,end):
    while end < len(text) and text[end] in " \t": end+=1
    if end < len(text) and text[end]=="\n": end+=1
    return end

def remove_block(text, marker):
    start=text.find(marker)
    if start < 0: return text
    return text[:start]+text[trim(text, balanced_end(text,start)):]

def replace_function(text, signature, replacement):
    start=text.find(signature)
    if start < 0: raise SystemExit(f"missing function: {signature}")
    end=trim(text, balanced_end(text,start))
    return text[:start]+replacement.rstrip()+"\n"+text[end:]

config.write_text("""import Foundation

struct Config {
    static let byeTunesApiUrl = ""
    static let byeTunesApiHost = ""
    static let downloadBackendLabel = "Disabled"
}
""")

dv=download.read_text()
dv=remove_block(dv, "    private func fetchSpotifyMetadata(url: String) async -> [String: Any]? {")
marker="        if let json = await fetchSpotifyMetadata(url: sourceURL)"
while marker in dv:
    dv=remove_block(dv, marker)

if "/api/download" in dv or "Config.byeTunesApiUrl" in dv:
    dv=replace_function(dv, "    private func downloadBackendCandidates(", """    private func downloadBackendCandidates(
        for source: DownloadSourceChoice,
        track: DownloadTrack? = nil
    ) async throws -> [BackendCandidate] {
        _ = source
        _ = track
        return []
    }""")

for forbidden in ("/api/metadata","/api/download","Config.byeTunesApiUrl"):
    if forbidden in dv:
        raise SystemExit(f"private ByeTunes backend marker remains: {forbidden}")
download.write_text(dv)
PY
! grep -Fq '/api/metadata' "$DOWNLOAD"
! grep -Fq '/api/download' "$DOWNLOAD"
! grep -Fq 'ByeTunesApiUrl' "$CONFIG"
echo "Disabled private ByeTunes backend; preserved upstream v2.5 lyrics"
