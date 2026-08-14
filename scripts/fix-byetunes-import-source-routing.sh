#!/bin/bash
set -euo pipefail

TARGET="ByeTunesMetadataCompat.swift"
test -f "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

start_marker = "    static func selectedSources() -> [MetadataProviderID] {\n"
end_marker = "\n    static func saveSources(_ sources: [MetadataProviderID]) {\n"

new = '''    static func selectedSources() -> [MetadataProviderID] {
        // The visible Import Metadata Source picker is authoritative. Do not
        // let a stale pre-v2.4 metadataSourcesJSON value silently turn Local
        // Files into All Sources after an upgrade or settings change.
        //
        // SongMetadata.fromURL has already parsed embedded file tags before
        // this function is consumed. These are therefore REMOTE enrichment
        // providers only. Local Files intentionally returns none.
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
            return [.youtube, .itunes, .deezer, .apple]
        default:
            return []
        }
    }
'''

start = text.find(start_marker)
end = text.find(end_marker, start + len(start_marker)) if start >= 0 else -1
if start < 0 or end < 0:
    raise SystemExit(
        f"selectedSources boundaries not found: start={start} end={end}"
    )

text = text[:start] + new + text[end:]

required = [
    "visible Import Metadata Source picker is authoritative",
    'case "youtube":\n            return [.youtube]',
    'case "itunes":\n            return [.itunes]',
    'case "deezer":\n            return [.deezer]',
    'case "apple":\n            return [.apple]',
    'case "all":\n            return [.youtube, .itunes, .deezer, .apple]',
    'default:\n            return []',
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"missing import-routing marker: {marker}")

# selectedSources itself must no longer consult the JSON provider list.
selected_block = text[start:text.find(end_marker, start)]
if "sourcesKey" in selected_block or "JSONDecoder" in selected_block:
    raise SystemExit("selectedSources still reads stale metadataSourcesJSON")

path.write_text(text)
print("Applied ByeTunes authoritative import-source routing")
PY
