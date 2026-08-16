#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current/Generated/Mond"
SBX="$ROOT/helpers_sbx.swift"
SETTINGS="$ROOT/views_App_SettingsView.swift"

test -f "$SBX" || { echo "Mond token patch requires staged helpers_sbx.swift" >&2; exit 1; }
test -f "$SETTINGS" || { echo "Mond token patch requires staged SettingsView.swift" >&2; exit 1; }

python3 - "$SBX" "$SETTINGS" <<'PY'
from pathlib import Path
import sys

sbx = Path(sys.argv[1])
settings = Path(sys.argv[2])
text = sbx.read_text(encoding="utf-8")


def replace_swift_function(text: str, signature: str, replacement: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"Mond token patch failed: function anchor missing: {signature}")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"Mond token patch failed: opening brace missing: {signature}")
    depth = 0
    in_string = False
    escape = False
    end = None
    for i in range(brace, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit(f"Mond token patch failed: closing brace missing: {signature}")
    return text[:start] + replacement + text[end:]

# Current SandboxSPI ABI from WebKit is:
# sandbox_extension_issue_file(extension_class, path, uint32_t flags).
issue = '''func mondCurrentSandboxExtensionIssueFile(path: String) -> String? {
    typealias sbx_issue_func = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    guard let libsys_sbx = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else {
        print("(mond) Generate Token failed: libsystem_sandbox unavailable")
        return nil
    }
    defer { dlclose(libsys_sbx) }

    guard let sbx_issue_sym = dlsym(libsys_sbx, "sandbox_extension_issue_file") else {
        print("(mond) Generate Token failed: sandbox_extension_issue_file unavailable")
        return nil
    }
    let issue = unsafeBitCast(sbx_issue_sym, to: sbx_issue_func.self)

    let ptr = "com.apple.app-sandbox.read-write".withCString { classPtr in
        path.withCString { pathPtr in
            issue(classPtr, pathPtr, 0)
        }
    }
    guard let ptr else {
        print("(mond) Generate Token failed: fresh sandbox extension was not issued")
        return nil
    }
    defer { free(ptr) }

    let value = String(cString: ptr)
    guard !value.isEmpty else {
        print("(mond) Generate Token failed: fresh sandbox extension was empty")
        return nil
    }

    print("(mond) Generate Token issued fresh sandbox token (\\(value.utf8.count) bytes)")
    return value
}'''

text = replace_swift_function(
    text,
    "func mondCurrentSandboxExtensionIssueFile(path: String) -> String? {",
    issue,
)
sbx.write_text(text, encoding="utf-8")

# Upstream Mond used sandbox_extension_consume(token) inside a SwiftUI computed
# property. SwiftUI may evaluate body repeatedly, so the UI itself could consume
# the displayed token multiple times and then render it as invalid. Never consume
# the user's token merely to paint status text. Track only a token freshly issued
# by this visible Settings instance; older/pasted tokens are shown as present,
# not falsely declared invalid.
settings_text = settings.read_text(encoding="utf-8")

# Remove the earlier persistent bookkeeping variant if this patch is applied on
# top of an already-adapted generated tree.
settings_text = settings_text.replace(
    '\n    @AppStorage("token_last_issued") private var token_last_issued: String = ""',
    '',
    1,
)

state_anchor = '@State private var show_confirm: Bool = false'
state_line = '@State private var lastFreshToken: String = ""'
if state_line not in settings_text:
    if state_anchor not in settings_text:
        raise SystemExit("Mond token patch failed: Settings state anchor missing")
    settings_text = settings_text.replace(
        state_anchor,
        state_anchor + '\n    ' + state_line,
        1,
    )

old_valid_upstream = '''var valid: Bool {
        (mondCurrentSandboxExtensionConsume(token) ?? -1) >= 0
    }'''
old_valid_previous = '''var valid: Bool {
        !token.isEmpty && token != "Failed to get token." && token == token_last_issued
    }'''
new_status = '''var tokenWasFreshlyIssued: Bool {
        !token.isEmpty && token != "Failed to get token." && token == lastFreshToken
    }'''
if old_valid_upstream in settings_text:
    settings_text = settings_text.replace(old_valid_upstream, new_status, 1)
elif old_valid_previous in settings_text:
    settings_text = settings_text.replace(old_valid_previous, new_status, 1)
elif new_status not in settings_text:
    raise SystemExit("Mond token patch failed: token status block anchor changed")

old_generate_upstream = 'token = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) ?? "Failed to get token."'
old_generate_previous = '''if let generated = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) {
                            token = generated
                            token_last_issued = generated
                        } else {
                            token = "Failed to get token."
                            token_last_issued = ""
                        }'''
new_generate = '''if let generated = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) {
                            token = generated
                            lastFreshToken = generated
                            print("(mond) Generate Token preserved fresh sandbox token without consuming it")
                        } else {
                            token = "Failed to get token."
                            lastFreshToken = ""
                        }'''
if old_generate_upstream in settings_text:
    settings_text = settings_text.replace(old_generate_upstream, new_generate, 1)
elif old_generate_previous in settings_text:
    settings_text = settings_text.replace(old_generate_previous, new_generate, 1)
elif new_generate not in settings_text:
    raise SystemExit("Mond token patch failed: Generate Token action anchor changed")

old_footer = '''if !token.isEmpty && token != "Failed to get token." {
                        if valid {
                            Text("Your sandbox token is valid.")
                        } else {
                            Text("Your sandbox token is invalid.")
                        }
                    }'''
new_footer = '''if !token.isEmpty && token != "Failed to get token." {
                        if tokenWasFreshlyIssued {
                            Text("Fresh sandbox token issued successfully. Mond has not consumed it.")
                        } else {
                            Text("Sandbox token present. Mond will not consume it just to validate the UI.")
                        }
                    }'''
if old_footer in settings_text:
    settings_text = settings_text.replace(old_footer, new_footer, 1)
elif new_footer not in settings_text:
    raise SystemExit("Mond token patch failed: token footer anchor changed")

settings.write_text(settings_text, encoding="utf-8")
PY

# Preserve upstream actions while enforcing a non-destructive token UI.
grep -Fq 'grant_all(state: state)' "$SETTINGS"
grep -Fq 'Text("Run Exploit")' "$SETTINGS"
grep -Fq 'Text("Generate Token")' "$SETTINGS"
grep -Fq '.disabled(!state.exploit_succeeded)' "$SETTINGS"

grep -Fq 'UInt32' "$SBX"
grep -Fq 'issue(classPtr, pathPtr, 0)' "$SBX"
! grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0, 0)' "$SBX"

grep -Fq '@State private var lastFreshToken: String = ""' "$SETTINGS"
grep -Fq 'token == lastFreshToken' "$SETTINGS"
grep -Fq 'Generate Token preserved fresh sandbox token without consuming it' "$SETTINGS"
grep -Fq 'Fresh sandbox token issued successfully. Mond has not consumed it.' "$SETTINGS"
grep -Fq 'Sandbox token present. Mond will not consume it just to validate the UI.' "$SETTINGS"
! grep -Fq 'mondCurrentSandboxExtensionConsume(token)' "$SETTINGS"
! grep -Fq 'Your sandbox token is invalid.' "$SETTINGS"
! grep -Fq '@AppStorage("token_last_issued")' "$SETTINGS"

# Block old captured-token UI plumbing from returning.
! grep -Fq 'Generate Token loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Run Exploit populated captured token' "$SETTINGS"
! grep -Fq 'Settings loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Generate Token using captured exploit token' "$SBX"

echo "Patched Mond to preserve generated sandbox tokens and never consume them for UI validation"
