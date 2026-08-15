#!/usr/bin/env bash
set -euo pipefail

TARGET="ThirdParty/mond-current/Generated/Mond/views_Tweaks_GestaltView.swift"
HOST="FilzaMondCurrentHost.swift"
SUPPORT="MondIOS27KeySupport.swift"
MOND_ROOT="ThirdParty/mond-current/Generated/Mond"
MOND_BQ_C="ThirdParty/mond-current/Generated/mond_bad_query.c"
MOND_BQ_H="ThirdParty/mond-current/Generated/mond_bad_query.h"

for path in "$TARGET" "$HOST" "$SUPPORT" "$MOND_ROOT/exploit_cmg.swift" "$MOND_ROOT/helpers_sbx.swift" "$MOND_ROOT/views_App_SettingsView.swift" "$MOND_BQ_C" "$MOND_BQ_H"; do
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

# Mond's SettingsView asks libsystem_sandbox to mint a second extension after
# the selected exploit already obtained one from ContainerManager. In a jailed
# Filza host that direct issuer call may return nil even though bad_query/CMG
# already succeeded. Preserve the exact MobileGestalt token produced by the
# exploit and use it as the Generate Token fallback. This does not synthesize
# or forge a token; it keeps the token ContainerManager actually returned.
python3 - "$MOND_ROOT" "$MOND_BQ_C" "$MOND_BQ_H" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
bq_c = Path(sys.argv[2])
bq_h = Path(sys.argv[3])
cmg = root / "exploit_cmg.swift"
sbx = root / "helpers_sbx.swift"
settings = root / "views_App_SettingsView.swift"

# CMG: container_object_get_sandbox_token returns a C string. Upstream prints
# the pointer itself (0x...) and then activates the result object. Copy the
# string while the object is alive so Settings can expose the real token.
text = cmg.read_text(encoding="utf-8")
if "mondCurrentCMGSandboxToken" not in text:
    anchor = "var g_fd: Int32 = -1\n"
    if anchor not in text:
        raise SystemExit("Mond token overlay failed: CMG g_fd anchor changed")
    text = text.replace(anchor, anchor + "var mondCurrentCMGSandboxToken: String? = nil\n", 1)

    old = '''    let tkn = get_tkn(res)\n    print("(cmg) token:", tkn ?? "nil")\n    guard activate(res, true) else { free(q); return -1 }'''
    new = '''    let tkn = get_tkn(res)\n    if let tkn {\n        let tokenText = String(cString: tkn)\n        mondCurrentCMGSandboxToken = tokenText.isEmpty ? nil : tokenText\n        print("(cmg) captured MobileGestalt sandbox token bytes: \\(tokenText.utf8.count)")\n    } else {\n        mondCurrentCMGSandboxToken = nil\n        print("(cmg) token: nil")\n    }\n    guard activate(res, true) else { free(q); return -1 }'''
    if old not in text:
        raise SystemExit("Mond token overlay failed: CMG token anchor changed")
    text = text.replace(old, new, 1)
    cmg.write_text(text, encoding="utf-8")

# bad_query: preserve only the token obtained for the MobileGestalt SystemGroup.
# grant_pb() runs after grant_mg(), so a generic last-token cache would be wrong.
text = bq_c.read_text(encoding="utf-8")
if "g_last_mg_token" not in text:
    anchor = "static int g_fd = -1;\n"
    if anchor not in text:
        raise SystemExit("Mond token overlay failed: bad_query g_fd anchor changed")
    text = text.replace(anchor, anchor + "static char *g_last_mg_token = NULL;\n", 1)

    old = '''    // printf("(bq) token: %s", token);\n    \n    // Consume our fresh sandbox extension and clean up'''
    new = '''    if (strstr(path, "systemgroup.com.apple.mobilegestaltcache") != NULL) {\n        free(g_last_mg_token);\n        g_last_mg_token = strdup(token);\n        if (g_last_mg_token) {\n            printf("(bq) captured MobileGestalt sandbox token: %zu bytes\\n", strlen(g_last_mg_token));\n        }\n    }\n    \n    // Consume our fresh sandbox extension and clean up'''
    if old not in text:
        raise SystemExit("Mond token overlay failed: bad_query token anchor changed")
    text = text.replace(old, new, 1)

    release_anchor = "void mond_bad_query_release(int64_t handle) {"
    if release_anchor not in text:
        raise SystemExit("Mond token overlay failed: bad_query release anchor changed")
    getter = '''char *mond_bad_query_copy_last_mg_token(void) {\n    return g_last_mg_token ? strdup(g_last_mg_token) : NULL;\n}\n\n'''
    text = text.replace(release_anchor, getter + release_anchor, 1)
    bq_c.write_text(text, encoding="utf-8")

text = bq_h.read_text(encoding="utf-8")
if "mond_bad_query_copy_last_mg_token" not in text:
    anchor = "void mond_bad_query_release(int64_t handle);"
    if anchor not in text:
        raise SystemExit("Mond token overlay failed: bad_query header anchor changed")
    text = text.replace(anchor, "char *mond_bad_query_copy_last_mg_token(void);\n" + anchor, 1)
    bq_h.write_text(text, encoding="utf-8")

# Settings helper: try upstream's direct issuer first. If the jailed host is not
# allowed to mint a second extension, return the token captured from the exploit
# selected in Mond settings.
text = sbx.read_text(encoding="utf-8")
if "mondCurrentCapturedExploitToken" not in text:
    issue_anchor = "func mondCurrentSandboxExtensionIssueFile(path: String) -> String? {"
    if issue_anchor not in text:
        raise SystemExit("Mond token overlay failed: sandbox issue helper anchor changed")
    helper = '''func mondCurrentCapturedExploitToken() -> String? {\n    let method = UserDefaults.standard.string(forKey: "method") ?? "bad_query"\n    if method == "cmg" {\n        return mondCurrentCMGSandboxToken\n    }\n\n    guard let ptr = mond_bad_query_copy_last_mg_token() else { return nil }\n    defer { free(ptr) }\n    let value = String(cString: ptr)\n    return value.isEmpty ? nil : value\n}\n\n'''
    text = text.replace(issue_anchor, helper + issue_anchor, 1)

    old = '''    guard let ptr = issue("com.apple.app-sandbox.read-write", path, 0, 0) else { return nil }\n    defer { free(ptr) }\n\n    return String(cString: ptr)'''
    new = '''    if let ptr = issue("com.apple.app-sandbox.read-write", path, 0, 0) {\n        defer { free(ptr) }\n        return String(cString: ptr)\n    }\n\n    let captured = mondCurrentCapturedExploitToken()\n    if let captured {\n        print("(mond) direct sandbox token issue unavailable; reusing captured exploit token (\\(captured.utf8.count) bytes)")\n    } else {\n        print("(mond) no captured MobileGestalt sandbox token is available")\n    }\n    return captured'''
    if old not in text:
        raise SystemExit("Mond token overlay failed: sandbox issue body changed")
    text = text.replace(old, new, 1)
    sbx.write_text(text, encoding="utf-8")

# Make exploit state visible. The original button has no success UI, which made
# successful handles look like a no-op even when exploit_succeeded was true.
text = settings.read_text(encoding="utf-8")
if "Exploit access is active" not in text:
    anchor = '''                } footer: {\n                    Text(method == "cmg" ? "**CMG:** Supports iOS 27.0 b1 - b4. PosterBoard wont work with this method. Only use this when bad_query isnt working for you." : "**bad_query:** Supports iOS 27.0 b1 - b4. By [forcequit](https://github.com/forcequitOS).")\n                }'''
    replacement = '''                } footer: {\n                    VStack(alignment: .leading, spacing: 6) {\n                        Text(method == "cmg" ? "**CMG:** Supports iOS 27.0 b1 - b4. PosterBoard wont work with this method. Only use this when bad_query isnt working for you." : "**bad_query:** Supports iOS 27.0 b1 - b4. By [forcequit](https://github.com/forcequitOS).")\n                        if state.exploit_succeeded {\n                            Text("Exploit access is active.")\n                                .foregroundStyle(.green)\n                        }\n                    }\n                }'''
    if anchor not in text:
        raise SystemExit("Mond token overlay failed: Settings exploit footer anchor changed")
    text = text.replace(anchor, replacement, 1)
    settings.write_text(text, encoding="utf-8")
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
grep -Fq 'mondCurrentCMGSandboxToken' "$MOND_ROOT/exploit_cmg.swift" || {
  echo "Mond token overlay failed: CMG token capture missing" >&2
  exit 1
}
grep -Fq 'mond_bad_query_copy_last_mg_token' "$MOND_BQ_C" || {
  echo "Mond token overlay failed: bad_query MG token capture missing" >&2
  exit 1
}
grep -Fq 'mondCurrentCapturedExploitToken' "$MOND_ROOT/helpers_sbx.swift" || {
  echo "Mond token overlay failed: Settings token fallback missing" >&2
  exit 1
}
grep -Fq 'Exploit access is active.' "$MOND_ROOT/views_App_SettingsView.swift" || {
  echo "Mond token overlay failed: exploit state UI missing" >&2
  exit 1
}

if grep -R -Fq 'Color("AccentColor")' ThirdParty/mond-current/Generated/Mond; then
  echo "Mond appearance parity failed: embedded views still resolve Filza AccentColor" >&2
  exit 1
fi

echo "Patched current upstream Mond with iOS 27 keys, exact accent color, and real exploit-token handoff"
