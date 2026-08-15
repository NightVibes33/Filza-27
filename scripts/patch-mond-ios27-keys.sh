#!/usr/bin/env bash
set -euo pipefail

TARGET="ThirdParty/mond-current/Generated/Mond/views_Tweaks_GestaltView.swift"
HOST="FilzaMondCurrentHost.swift"
SUPPORT="MondIOS27KeySupport.swift"

for path in "$TARGET" "$HOST" "$SUPPORT"; do
  test -f "$path" || { echo "Missing Mond iOS 27 overlay input: $path" >&2; exit 1; }
done

python3 - "$TARGET" "$SUPPORT" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
support_path = Path(sys.argv[2])
text = target.read_text(encoding="utf-8")

marker = "// FILZA_IOS27_GESTALT_KEYS_BEGIN"
if marker not in text:
    needle = '''                Section {\n                    MondCurrentPlainToggle(text: "Camera Control"'''
    if needle not in text:
        raise SystemExit("Mond iOS 27 overlay failed: upstream Hardware-Oriented Features anchor changed")

    overlay = '''                // FILZA_IOS27_GESTALT_KEYS_BEGIN
                // Project-requested iOS 27 keys layered onto the exact current
                // upstream Mond GestaltView. This does not replace upstream UI.
                if mondCurrentSystemVersion() >= 27.0 {
                    Section {
                        ForEach(mondIOS27GestaltKeys) { definition in
                            if definition.preferredKind == .boolean {
                                MondIOS27GestaltKeyToggle(
                                    definition: definition,
                                    isOn: mg_key_binding([definition.key])
                                )
                            } else {
                                MondIOS27RawGestaltKeyRow(
                                    definition: definition,
                                    value: (mg_dict_now["CacheExtra"] as? NSMutableDictionary)?[definition.key]
                                ) { value in
                                    guard let extra = mg_dict_now["CacheExtra"] as? NSMutableDictionary else { return }
                                    if let value = value {
                                        extra[definition.key] = value
                                    } else {
                                        extra.removeObject(forKey: definition.key)
                                    }
                                }
                                .id("\\(definition.key):\\(mondIOS27ScalarText((mg_dict_now[\"CacheExtra\"] as? NSMutableDictionary)?[definition.key]))")
                            }
                        }
                    } header: {
                        Label("iOS 27 Gestalt Keys", systemImage: "cpu")
                    } footer: {
                        Text("iOS 27 beta 1–5 key mappings requested for this Filza integration. Apply Tweaks writes the changes; Revert Tweaks restores Mond's saved original plist.")
                    }
                }
                // FILZA_IOS27_GESTALT_KEYS_END

'''
    text = text.replace(needle, overlay + needle, 1)

# The support declarations are staged into the same compiled upstream source
# file so Makefile source discovery stays deterministic and MondGestaltView.swift
# remains retired from the build graph.
if "enum MondIOS27GestaltScalarKind" not in text:
    support = support_path.read_text(encoding="utf-8")
    support = "\n".join(
        line for line in support.splitlines()
        if not line.startswith("import ")
    ).strip()
    text = text.rstrip() + "\n\n" + support + "\n"

# Upstream Mond resolves AccentColor from its own asset catalog. Embedded in
# Filza, Bundle.main would otherwise resolve Filza's asset instead. Keep the
# exact upstream RGB while deliberately leaving Bundle.main identity alone in
# Settings so the Filza app card/name/version remains visible.
text = text.replace(
    'Color("AccentColor")',
    'Color(red: 0.28529, green: 0.44118, blue: 0.92451)'
)

target.write_text(text, encoding="utf-8")
PY

# ContentView also uses Mond's AccentColor asset upstream.
python3 - <<'PY'
from pathlib import Path
root = Path("ThirdParty/mond-current/Generated/Mond")
for path in root.glob("*.swift"):
    text = path.read_text(encoding="utf-8")
    new = text.replace(
        'Color("AccentColor")',
        'Color(red: 0.28529, green: 0.44118, blue: 0.92451)'
    )
    if new != text:
        path.write_text(new, encoding="utf-8")
PY

grep -Fq '// FILZA_IOS27_GESTALT_KEYS_BEGIN' "$TARGET" || {
  echo "Mond iOS 27 overlay failed: section marker missing" >&2
  exit 1
}
grep -Fq 'DeviceSupportsHighLuminanceAlwaysOnDisplay' "$TARGET" || {
  echo "Mond iOS 27 overlay failed: staged key support table missing" >&2
  exit 1
}
grep -Fq 'DeviceSupportsInstructionFollowingPruningModels' "$TARGET" || {
  echo "Mond iOS 27 overlay failed: staged current iOS 27 key table incomplete" >&2
  exit 1
}
grep -Fq 'filzaMond_fix_init' "$HOST" || {
  echo "Mond bootstrap parity failed: document picker compatibility missing" >&2
  exit 1
}
grep -Fq '.onOpenURL' "$HOST" || {
  echo "Mond bootstrap parity failed: upstream URL handling missing" >&2
  exit 1
}

if grep -R -Fq 'Color("AccentColor")' ThirdParty/mond-current/Generated/Mond; then
  echo "Mond appearance parity failed: embedded views still resolve Filza AccentColor" >&2
  exit 1
fi

echo "Patched current upstream Mond with iOS 27 key overlay and exact upstream accent color"
