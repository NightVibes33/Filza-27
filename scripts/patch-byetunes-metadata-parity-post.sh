#!/bin/bash
set -euo pipefail

SETTINGS="ByeTunes/MusicManager/SettingsView.swift"
MUSIC="ByeTunes/MusicManager/MusicView.swift"
SONG="ByeTunes/MusicManager/SongMetadata.swift"

for path in "$SETTINGS" "$MUSIC" "$SONG"; do
    test -f "$path"
done

python3 - "$SETTINGS" "$MUSIC" "$SONG" <<'PY'
from pathlib import Path
import sys

settings = Path(sys.argv[1])
music = Path(sys.argv[2])
song = Path(sys.argv[3])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text and old not in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# The original pre-v2.4 settings only updated metadataSourcesJSON when the user
# changed the picker. Merely opening Settings must not rewrite provider state.
ss = settings.read_text()
old_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metadataSource) { newValue in
            persistMetadataSelection(newValue)
        }
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
            MetadataProviderSettings.migrateIfNeeded()
            persistMetadataSelection(metadataSource)
        }
'''
new_modifiers = '''        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metadataSource) { newValue in
            persistMetadataSelection(newValue)
        }
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
        }
'''
ss = replace_once(ss, old_modifiers, new_modifiers, "metadata settings open-state parity")

# Pre-v2.4 exposed Store Region for iTunes, Apple, and All.
ss = replace_once(
    ss,
    '                        if metadataSource == "itunes" || metadataSource == "all" {\n',
    '                        if metadataSource == "itunes" || metadataSource == "apple" || metadataSource == "all" {\n',
    "Store Region visibility parity",
)
settings.write_text(ss)


# Restore the old bookkeeping fields that identify where a queued song's
# metadata came from. v2.4 removed them along with MetadataProvider.swift, but
# the pre-v2.4 import pipeline populated them deliberately.
sms = song.read_text()
anchor = '''    var richAppleMetadataFetched: Bool = false
'''
addition = '''    var richAppleMetadataFetched: Bool = false
    var youtubeVideoID: String? = nil
    var metadataSourcesUsed: [MetadataProviderID] = []
'''
sms = replace_once(sms, anchor, addition, "SongMetadata provider provenance fields")
song.write_text(sms)


# Keep source-use bookkeeping aligned with the original import pipeline. This
# does not decide which provider runs; MetadataProviderSettings.selectedSources
# already does that using the original state machine restored before this patch.
ms = music.read_text()
loop_anchor = '''            if autofetch {
                let sources = MetadataProviderSettings.selectedSources()
                Logger.shared.log("[MusicView] Filza embed metadata compatibility sources=\\(sources.map(\\.rawValue).joined(separator: ","))")
                for source in sources {
'''
loop_replacement = '''            var sourcesUsed: [MetadataProviderID] = [.local]
            if autofetch {
                let sources = MetadataProviderSettings.selectedSources()
                Logger.shared.log("[MusicView] metadata sources=\\(sources.map(\\.rawValue).joined(separator: ","))")
                for source in sources {
'''
ms = replace_once(ms, loop_anchor, loop_replacement, "MusicView provider provenance start")

# Update each provider case only after an enrichment actually changes/identifies
# the song, matching the old ByeTunes intent instead of claiming every selected
# provider succeeded.
old_cases = '''                    case .local:
                        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                            song = await SongMetadata.matchAppleMusicMetadata(song)
                        }
                    case .youtube:
                        song = await MetadataProvider.enrichSongMetadata(song)
                    case .itunes:
                        song = await SongMetadata.enrichWithiTunesMetadata(song)
                    case .deezer:
                        song = await SongMetadata.enrichWithDeezerMetadata(song)
                    case .apple:
                        song = await SongMetadata.enrichWithAppleMusicMetadata(song)
                    }
                }
            }
'''
new_cases = '''                    case .local:
                        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
                            let enriched = await SongMetadata.matchAppleMusicMetadata(song)
                            if enriched.richAppleMetadataFetched {
                                song = enriched
                                if !sourcesUsed.contains(.apple) { sourcesUsed.append(.apple) }
                            }
                        }
                    case .youtube:
                        let beforeTitle = song.title
                        let beforeArtist = song.artist
                        let enriched = await MetadataProvider.enrichSongMetadata(song)
                        song = enriched
                        if enriched.title != beforeTitle || enriched.artist != beforeArtist {
                            if !sourcesUsed.contains(.youtube) { sourcesUsed.append(.youtube) }
                        }
                    case .itunes:
                        let enriched = await SongMetadata.enrichWithiTunesMetadata(song)
                        if enriched.title != song.title || enriched.artist != song.artist {
                            song = enriched
                            if !sourcesUsed.contains(.itunes) { sourcesUsed.append(.itunes) }
                        }
                    case .deezer:
                        let enriched = await SongMetadata.enrichWithDeezerMetadata(song)
                        if enriched.title != song.title || enriched.artist != song.artist {
                            song = enriched
                            if !sourcesUsed.contains(.deezer) { sourcesUsed.append(.deezer) }
                        }
                    case .apple:
                        let enriched = await SongMetadata.enrichWithAppleMusicMetadata(song)
                        if enriched.richAppleMetadataFetched {
                            song = enriched
                            if !sourcesUsed.contains(.apple) { sourcesUsed.append(.apple) }
                        }
                    }
                }
            }
            song.metadataSourcesUsed = sourcesUsed
'''
ms = replace_once(ms, old_cases, new_cases, "MusicView provider provenance cases")
music.write_text(ms)

print("Applied original ByeTunes metadata parity post-patch")
PY

grep -Fq 'persistMetadataSelection(newValue)' "$SETTINGS"
! grep -A8 -F '.onAppear {' "$SETTINGS" | grep -Fq 'persistMetadataSelection(metadataSource)'
grep -Fq 'metadataSource == "itunes" || metadataSource == "apple" || metadataSource == "all"' "$SETTINGS"
grep -Fq 'var youtubeVideoID: String? = nil' "$SONG"
grep -Fq 'var metadataSourcesUsed: [MetadataProviderID] = []' "$SONG"
grep -Fq 'song.metadataSourcesUsed = sourcesUsed' "$MUSIC"
grep -Fq '[MusicView] metadata sources=' "$MUSIC"

echo "Verified original ByeTunes metadata state semantics"
