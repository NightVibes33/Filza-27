#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
MOND_GEN="$ROOT/Generated/Mond"
PARTY_HELPERS="$ROOT/Generated/PartyUI/Utilities_Helpers.swift"
UPSTREAM="$ROOT/Upstream"
ACCENT_JSON="$UPSTREAM/other/Assets.xcassets/AccentColor.colorset/Contents.json"

for path in \
  "$MOND_GEN/views_app_ContentView.swift" \
  "$MOND_GEN/views_app_SettingsView.swift" \
  "$MOND_GEN/views_tweaks_GestaltView.swift" \
  "$MOND_GEN/exploit_unsbx.swift" \
  "$MOND_GEN/helpers_mg.swift" \
  "$PARTY_HELPERS" \
  "$ACCENT_JSON"; do
  test -f "$path" || { echo "Missing Mond parity input: $path" >&2; exit 1; }
done

# The immutable upstream snapshot stays untouched. These adaptations only make
# resources/defaults/bundle identity supplied by Mond's standalone app target
# explicit when the same source is hosted inside Filza's process.
python3 - "$MOND_GEN" "$PARTY_HELPERS" "$ACCENT_JSON" <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1])
party_helpers = Path(sys.argv[2])
accent_path = Path(sys.argv[3])
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

    # SettingsView reads name/version/icon from Bundle.main. In an embedded
    # process that is Filza, not Mond. Point only the generated embedded copy to
    # the staged pinned Mond resource bundle.
    text = text.replace('Bundle.main', 'MondEmbeddedParity.bundle')
    text = text.replace(
        'UIImage(named: icon)',
        'UIImage(named: icon, in: MondEmbeddedParity.bundle, compatibleWith: nil)'
    )

    path.write_text(text, encoding="utf-8")

# PartyUI's AppInfo helper has the same Bundle.main assumption. Keep its pinned
# source behavior while supplying Mond's embedded resource bundle explicitly.
party = party_helpers.read_text(encoding="utf-8")
party = party.replace('Bundle.main', 'MondEmbeddedParity.bundle')
party = party.replace(
    'UIImage(named: lastIcon)',
    'UIImage(named: lastIcon, in: MondEmbeddedParity.bundle, compatibleWith: nil)'
)
party_helpers.write_text(party, encoding="utf-8")
PY

# Prove the upstream snapshot stayed exact while the generated embedded copy got
# only the host-environment adaptations above. Mond 2.2 moved GestaltView under
# views/tweaks/mobilegestalt and added CEView alongside it.
grep -Fq 'Color("AccentColor")' "$UPSTREAM/views/app/ContentView.swift"
grep -Fq 'Color("AccentColor")' "$UPSTREAM/views/tweaks/mobilegestalt/GestaltView.swift"
grep -Fq 'UserDefaults.standard.string(forKey: "method")' "$UPSTREAM/exploit/unsbx.swift"
grep -Fq 'Bundle.main.infoDictionary' "$UPSTREAM/views/app/SettingsView.swift"

grep -Fq 'MondEmbeddedParity.accentColor' "$MOND_GEN/views_app_ContentView.swift"
grep -Fq 'MondEmbeddedParity.accentColor' "$MOND_GEN/views_tweaks_GestaltView.swift"
grep -Fq '@AppStorage("method", store: MondEmbeddedParity.defaults)' "$MOND_GEN/views_app_ContentView.swift"
grep -Fq '@AppStorage("method", store: MondEmbeddedParity.defaults)' "$MOND_GEN/views_app_SettingsView.swift"
grep -Fq '@AppStorage("ignore_failure", store: MondEmbeddedParity.defaults)' "$MOND_GEN/views_app_ContentView.swift"
grep -Fq '@AppStorage("atomic_write", store: MondEmbeddedParity.defaults)' "$MOND_GEN/views_app_SettingsView.swift"
grep -Fq 'MondEmbeddedParity.defaults.string(forKey: "method")' "$MOND_GEN/exploit_unsbx.swift"
grep -Fq 'MondEmbeddedParity.defaults.string(forKey: mg_device_name_key)' "$MOND_GEN/helpers_mg.swift"
grep -Fq 'MondEmbeddedParity.bundle.infoDictionary' "$MOND_GEN/views_app_SettingsView.swift"
grep -Fq 'UIImage(named: icon, in: MondEmbeddedParity.bundle, compatibleWith: nil)' "$MOND_GEN/views_app_SettingsView.swift"
grep -Fq 'MondEmbeddedParity.bundle.infoDictionary' "$PARTY_HELPERS"
grep -Fq 'UIImage(named: lastIcon, in: MondEmbeddedParity.bundle, compatibleWith: nil)' "$PARTY_HELPERS"

! grep -R -Fq 'Color("AccentColor")' "$MOND_GEN"
! grep -R -Fq 'UserDefaults.standard' "$MOND_GEN"
! grep -R -Fq 'Bundle.main' "$MOND_GEN"
! grep -Fq 'Bundle.main' "$PARTY_HELPERS"

echo "Embedded Mond 2.2 parity adapter applied: upstream accent + dedicated defaults + Mond bundle identity"
