#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current/Generated/Mond"
SBX="$ROOT/helpers_sbx.swift"
SETTINGS="$ROOT/views_App_SettingsView.swift"

test -f "$SBX" || { echo "Mond token patch requires staged helpers_sbx.swift" >&2; exit 1; }
test -f "$SETTINGS" || { echo "Mond token patch requires staged SettingsView.swift" >&2; exit 1; }

python3 - "$SBX" <<'PY'
from pathlib import Path
import sys

sbx = Path(sys.argv[1])
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

# WebKit's current SandboxSPI declares sandbox_extension_issue_file as
# (extension_class, path, uint32_t flags). Keep that ABI correction, but restore
# Mond's real behavior: Generate Token must mint a fresh token after Run Exploit
# succeeds. Never substitute the token bad_query already consumed internally.
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

    guard let ptr = issue("com.apple.app-sandbox.read-write", path, 0) else {
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
PY

# Preserve the real upstream Settings button semantics. The staging namespace
# changes function/type names only; these actions should otherwise remain the
# same as rooootdev/mond.
grep -Fq 'grant_all(state: state)' "$SETTINGS"
grep -Fq 'Text("Run Exploit")' "$SETTINGS"
grep -Fq 'token = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) ?? "Failed to get token."' "$SETTINGS"
grep -Fq 'Text("Generate Token")' "$SETTINGS"
grep -Fq '.disabled(!state.exploit_succeeded)' "$SETTINGS"

# Block the old Filza-specific captured-token UI plumbing from returning.
! grep -Fq 'Generate Token loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Run Exploit populated captured token' "$SETTINGS"
! grep -Fq 'Settings loaded captured exploit token' "$SETTINGS"
! grep -Fq 'Generate Token using captured exploit token' "$SBX"

grep -Fq 'UInt32' "$SBX"
grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0)' "$SBX"
! grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0, 0)' "$SBX"

echo "Restored Mond manual Run Exploit -> fresh Generate Token flow with corrected SandboxSPI ABI"
