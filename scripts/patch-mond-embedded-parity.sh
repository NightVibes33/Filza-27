#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
GEN="$ROOT/Generated/Mond"
UPSTREAM="$ROOT/Upstream"
ACCENT_JSON="$UPSTREAM/other/Assets.xcassets/AccentColor.colorset/Contents.json"

for path in \
  "$GEN/views_app_ContentView.swift" \
  "$GEN/views_app_SettingsView.swift" \
  "$GEN/views_tweaks_GestaltView.swift" \
  "$GEN/exploit_unsbx.swift" \
  "$GEN/helpers_mg.swift" \
  "$ACCENT_JSON"; do
  test -f "$path" || { echo "Missing Mond parity input: $path" >&2; exit 1; }
done

# The immutable upstream snapshot stays untouched. These adaptations only make
# resources/defaults supplied by Mond's standalone app target explicit when the
# same source is hosted inside Filza's process.
python3 - "$GEN" "$ACCENT_JSON" <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1])
accent_path = Path(sys.argv[2])
accent = json.loads(accent_path.read_text(encoding="utf-8"))["colors"][0]["color"]["components"]

expected = {
    "red": "0.28529",
    "green": "0.44118",
    "blue": "0.92451",
    "alpha": "1.00000",
}
if accent != expected:
    raise SystemExit(f"Unexpected pinned Mond AccentColor: {accent!r}")

app_storage = re.compile(r'@AppStorage\(("[^"\\]*(?:\\.[^"\\]*)*")\)')

for path in sorted(root.glob("*.swift")):
    text = path.read_text(encoding="utf-8")

    # Standalone Mond gets this color from Assets.xcassets. Filza does not own
    # that asset catalog, so route the generated copy to the exact same RGBA
    # supplied by MondEmbeddedParity.
    text = text.replace('Color("AccentColor")', 'MondEmbeddedParity.accentColor')

    # Standalone Mond's UserDefaults.standard domain is com.roooot.mond. When
    # hosted in Filza, standard belongs to Filza instead. Route only the staged
    # generated Mond copy to the dedicated Mond defaults suite.
    text = text.replace('UserDefaults.standard', 'MondEmbeddedParity.defaults')
    text = app_storage.sub(r'@AppStorage(\1, store: MondEmbeddedParity.defaults)', text)

    path.write_text(text, encoding="utf-8")
PY

# Prove the upstream snapshot stayed exact while the generated embedded copy got
# only the host-environment adaptations above.
grep -Fq 'Color("AccentColor")' "$UPSTREAM/views/app/ContentView.swift"
grep -Fq 'Color("AccentColor")' "$UPSTREAM/views/tweaks/GestaltView.swift"
grep -Fq 'UserDefaults.standard.string(forKey: "method")' "$UPSTREAM/exploit/unsbx.swift"

grep -Fq 'MondEmbeddedParity.accentColor' "$GEN/views_app_ContentView.swift"
grep -Fq 'MondEmbeddedParity.accentColor' "$GEN/views_tweaks_GestaltView.swift"
grep -Fq '@AppStorage("method", store: MondEmbeddedParity.defaults)' "$GEN/views_app_ContentView.swift"
grep -Fq '@AppStorage("method", store: MondEmbeddedParity.defaults)' "$GEN/views_app_SettingsView.swift"
grep -Fq 'MondEmbeddedParity.defaults.string(forKey: "method")' "$GEN/exploit_unsbx.swift"
grep -Fq 'MondEmbeddedParity.defaults.string(forKey: mg_device_name_key)' "$GEN/helpers_mg.swift"

! grep -R -Fq 'Color("AccentColor")' "$GEN"
! grep -R -Fq 'UserDefaults.standard' "$GEN"

echo "Embedded Mond parity adapter applied: upstream accent + dedicated defaults domain"
