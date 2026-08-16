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

# sandbox_extension_issue_file is a 3-argument SandboxSPI call:
# (extension_class, path, uint32_t flags). Upstream Mond's pinned revision still
# declares the older 4-argument shape, which can mint an unusable token on the
# current runtime. Keep the exact ABI and explicit C-string lifetimes here.
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

# Do not use sandbox_extension_consume() as a SwiftUI computed validity check.
# `body` may evaluate repeatedly; consuming the token is stateful and also leaks
# the returned extension handle when used only as a boolean probe. Record the
# exact token successfully issued by this Mond instance and compare against it.
settings_text = settings.read_text(encoding="utf-8")
storage_anchor = '@AppStorage("token") private var token: String = ""'
storage_replacement = storage_anchor + '\n    @AppStorage("token_last_issued") private var token_last_issued: String = ""'
if '@AppStorage("token_last_issued")' not in settings_text:
    if storage_anchor not in settings_text:
        raise SystemExit("Mond token patch failed: token AppStorage anchor missing")
    settings_text = settings_text.replace(storage_anchor, storage_replacement, 1)

old_valid = '''var valid: Bool {
        (mondCurrentSandboxExtensionConsume(token) ?? -1) >= 0
    }'''
new_valid = '''var valid: Bool {
        !token.isEmpty && token != "Failed to get token." && token == token_last_issued
    }'''
if old_valid in settings_text:
    settings_text = settings_text.replace(old_valid, new_valid, 1)
elif new_valid not in settings_text:
    raise SystemExit("Mond token patch failed: validity block anchor changed")

old_generate = 'token = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) ?? "Failed to get token."'
new_generate = '''if let generated = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) {
                            token = generated
                            token_last_issued = generated
                        } else {
                            token = "Failed to get token."
                            token_last_issued = ""
                        }'''
if old_generate in settings_text:
    settings_text = settings_text.replace(old_generate, new_generate, 1)
elif new_generate not in settings_text:
    raise SystemExit("Mond token patch failed: Generate Token action anchor changed")

settings.write_text(settings_text, encoding="utf-8")
PY

# Preserve the real upstream Settings button semantics. The staging namespace
# changes function/type names only; these actions should otherwise remain the
# same as rooootdev/mond.
grep -Fq 'grant_all(state: state)' "$SETTINGS"
grep -Fq 'Text("Run Exploit")' "$SETTINGS"
grep -Fq 'Text("Generate Token")' "$SETTINGS"
grep -Fq '.disabled(!state.exploit_succeeded)' "$SETTINGS"

# Verify the current SandboxSPI ABI and the non-destructive validity path.
grep -Fq 'UInt32' "$SBX"
grep -Fq 'issue(classPtr, pathPtr, 0)' "$SBX"
! grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0, 0)' "$SBX"
grep -Fq '@AppStorage("token_last_issued")' "$SETTINGS"
grep -Fq 'token_last_issued = generated' "$SETTINGS"
grep -Fq 'token == token_last_issued' "$SETTINGS"
! grep -Fq '(mondCurrentSandboxExtensionConsume(token) ?? -1) >= 0' "$SETTINGS"

# Block the old Filza-specific captured-token UI plumbing from returning.
! grep -Fq 'Generate Token loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Run Exploit populated captured token' "$SETTINGS"
! grep -Fq 'Settings loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Generate Token using captured exploit token' "$SBX"

echo "Patched Mond fresh-token issuance and non-destructive token status validation"
