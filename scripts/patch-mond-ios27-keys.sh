#!/usr/bin/env bash
set -euo pipefail

TARGET="ThirdParty/mond-current/Generated/Mond/views_Tweaks_GestaltView.swift"
HOST="FilzaMondCurrentHost.swift"
SUPPORT="MondIOS27KeySupport.swift"
MOND_ROOT="ThirdParty/mond-current/Generated/Mond"

for path in "$TARGET" "$HOST" "$SUPPORT" "$MOND_ROOT/helpers_sbx.swift" "$MOND_ROOT/views_App_SettingsView.swift"; do
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

if "enum MondIOS27GestaltScalarKind" not in text:
    support = support_path.read_text(encoding="utf-8")
    support = "\n".join(
        line for line in support.splitlines()
        if not line.startswith("import ")
    ).strip()
    text = text.rstrip() + "\n\n" + support + "\n"

text = text.replace(
    'Color("AccentColor")',
    'Color(red: 0.28529, green: 0.44118, blue: 0.92451)'
)

target.write_text(text, encoding="utf-8")
PY

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
grep -Fq 'waiting for Run Exploit' "$HOST" || {
  echo "Mond manual exploit integration failed: embedded host still auto-runs exploit" >&2
  exit 1
}
grep -Fq 'grant_all(state: state)' "$MOND_ROOT/views_App_SettingsView.swift" || {
  echo "Mond manual exploit integration failed: upstream Run Exploit action missing" >&2
  exit 1
}
grep -Fq 'Text("Run Exploit")' "$MOND_ROOT/views_App_SettingsView.swift" || {
  echo "Mond manual exploit integration failed: upstream Run Exploit button missing" >&2
  exit 1
}
grep -Fq 'Text("Generate Token")' "$MOND_ROOT/views_App_SettingsView.swift" || {
  echo "Mond token integration failed: upstream Generate Token button missing" >&2
  exit 1
}

if grep -R -Fq 'Color("AccentColor")' ThirdParty/mond-current/Generated/Mond; then
  echo "Mond appearance parity failed: embedded views still resolve Filza AccentColor" >&2
  exit 1
fi

# These were old Filza-only token handoff hooks. They must not be regenerated.
! grep -R -Fq 'mondCurrentCapturedExploitToken' "$MOND_ROOT"
! grep -R -Fq 'Settings loaded captured exploit token' "$MOND_ROOT"
! grep -R -Fq 'Run Exploit populated captured token' "$MOND_ROOT"

echo "Patched current upstream Mond with iOS 27 keys and embedded appearance only; exploit remains manual"
