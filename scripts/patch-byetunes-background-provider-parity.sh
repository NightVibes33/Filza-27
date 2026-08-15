#!/bin/bash
set -euo pipefail

# Historical hook retained for Makefile compatibility. The pinned ByeTunes v2.4
# BackgroundMetadataFetchManager is now the source of truth; no reconstructed
# YouTube/provider layer is injected into the embedded build.

BACKGROUND="ByeTunes/MusicManager/BackgroundMetadataFetchManager.swift"
NETWORK="ByeTunes/MusicManager/MetadataBackgroundURLSession.swift"

test -f "$BACKGROUND"
test -f "$NETWORK"

grep -Fq 'let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"' "$BACKGROUND"
grep -Fq 'MetadataBackgroundURLSession.shared.data(for: request)' "$NETWORK"

echo "Verified upstream ByeTunes v2.4 background metadata behavior"
