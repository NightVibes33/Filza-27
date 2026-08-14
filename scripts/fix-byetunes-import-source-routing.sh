#!/bin/bash
set -euo pipefail

TARGET="ByeTunesMetadataCompat.swift"
test -f "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()

        if UserDefaults.standard.string(forKey: legacySourceKey) == "all" {
            return defaultSources
        }

        guard let json = UserDefaults.standard.string(forKey: sourcesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MetadataProviderID].self, from: data),
              !decoded.isEmpty else {
            return [.local]
        }
        return decoded
    }
'''

new = '''    static func selectedSources() -> [MetadataProviderID] {
        // The visible Import Metadata Source picker is the single source of
        // truth. The pre-v2.4 metadataSourcesJSON array can survive upgrades
        // with an old All selection, so consulting it here can make a visible
        // Local Files selection silently run every remote provider.
        //
        // Local file metadata is already parsed by SongMetadata.fromURL before
        // enrichment starts. Returning an empty remote-provider list for Local
        // keeps embedded tags authoritative and leaves filename/fallback values
        // in place only where the file itself has no tag.
        let selected = (UserDefaults.standard.string(forKey: legacySourceKey) ?? "local").lowercased()
        switch selected {
        case "youtube":
            return [.youtube]
        case "itunes":
            return [.itunes]
        case "deezer":
            return [.deezer]
        case "apple":
            return [.apple]
        case "all":
            // Local parsing already happened before this list is consumed.
            return [.youtube, .itunes, .deezer, .apple]
        default:
            return []
        }
    }
'''

if new in text and old not in text:
    pass
else:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"MetadataProviderSettings.selectedSources anchor mismatch: {count}")
    text = text.replace(old, new, 1)

path.write_text(text)
PY

# Fail closed: import routing must no longer read metadataSourcesJSON to decide
# what provider runs. That JSON remains only for backward-compatible settings
# persistence; the visible metadataSource picker is authoritative at runtime.
grep -Fq 'The visible Import Metadata Source picker is the single source of truth.' "$TARGET"
grep -Fq 'return [.youtube, .itunes, .deezer, .apple]' "$TARGET"
grep -Fq 'return []' "$TARGET"
