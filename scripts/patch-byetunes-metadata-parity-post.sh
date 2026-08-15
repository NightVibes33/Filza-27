#!/bin/bash
set -euo pipefail

# Historical hook retained for Makefile compatibility.
# Metadata behavior now comes directly from pinned ByeTunes v2.4. Do not add
# provider provenance fields, YouTube search behavior, or Settings rewrites here.

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MUSIC="ByeTunes/MusicManager/MusicView.swift"
SONG="ByeTunes/MusicManager/SongMetadata.swift"
NETWORK="ByeTunes/MusicManager/MetadataBackgroundURLSession.swift"

for path in "$SETTINGS" "$MUSIC" "$SONG" "$NETWORK"; do
    test -f "$path"
done

grep -Fq 'let metadataSource = UserDefaults.standard.string(forKey: "metadataSource") ?? "local"' "$MUSIC"
grep -Fq 'return try await URLSession.shared.data(for: request)' "$NETWORK"
! grep -Fq 'metadataSourcesUsed:' "$SONG"
! grep -Fq 'MetadataWebKitRequest' "$NETWORK"

echo "Verified pinned upstream ByeTunes metadata post-stage state"
