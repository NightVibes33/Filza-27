#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current/Generated/Mond"
SBX="$ROOT/helpers_sbx.swift"
SETTINGS="$ROOT/views_App_SettingsView.swift"
BQ="ThirdParty/mond-current/Generated/mond_bad_query.c"

test -f "$SBX" || { echo "Mond token patch requires staged helpers_sbx.swift" >&2; exit 1; }
test -f "$SETTINGS" || { echo "Mond token patch requires staged SettingsView.swift" >&2; exit 1; }
test -f "$BQ" || { echo "Mond token patch requires staged bad_query" >&2; exit 1; }
grep -Fq 'mond_bad_query_copy_last_mg_token' "$BQ"

python3 - "$SBX" "$SETTINGS" <<'PY'
from pathlib import Path
import sys

sbx = Path(sys.argv[1])
settings = Path(sys.argv[2])


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

text = sbx.read_text(encoding="utf-8")

captured = '''func mondCurrentCapturedExploitToken() -> String? {
    // bad_query captures the exact MobileGestalt ContainerManager extension
    // before upstream consumes/frees its original C string. Prefer that real
    // token regardless of the picker state so the UI cannot lose it because a
    // persisted method string is stale.
    if let ptr = mond_bad_query_copy_last_mg_token() {
        defer { free(ptr) }
        let value = String(cString: ptr)
        if !value.isEmpty { return value }
    }

    if let value = mondCurrentCMGSandboxToken, !value.isEmpty {
        return value
    }
    return nil
}'''
text = replace_swift_function(
    text,
    "func mondCurrentCapturedExploitToken() -> String? {",
    captured,
)

# Current WebKit SandboxSPI calls sandbox_extension_issue_file(class, path,
# uint32_t flags). Upstream Mond declared a fourth Int32 argument. Use the real
# three-argument ABI, while retaining the captured ContainerManager token as a
# fallback for a host process that is not allowed to issue a fresh extension.
issue = '''func mondCurrentSandboxExtensionIssueFile(path: String) -> String? {
    typealias sbx_issue_func = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    guard let libsys_sbx = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else {
        print("(mond) sandbox token issue failed: libsystem_sandbox unavailable")
        return mondCurrentCapturedExploitToken()
    }
    defer { dlclose(libsys_sbx) }

    guard let sbx_issue_sym = dlsym(libsys_sbx, "sandbox_extension_issue_file") else {
        print("(mond) sandbox token issue failed: sandbox_extension_issue_file unavailable")
        return mondCurrentCapturedExploitToken()
    }
    let issue = unsafeBitCast(sbx_issue_sym, to: sbx_issue_func.self)

    if let ptr = issue("com.apple.app-sandbox.read-write", path, 0) {
        defer { free(ptr) }
        let value = String(cString: ptr)
        if !value.isEmpty {
            print("(mond) Generate Token issued fresh sandbox token (\\(value.utf8.count) bytes)")
            return value
        }
    }

    if let captured = mondCurrentCapturedExploitToken() {
        print("(mond) Generate Token using captured exploit token (\\(captured.utf8.count) bytes)")
        return captured
    }

    print("(mond) Generate Token failed: no fresh or captured token available")
    return nil
}'''
text = replace_swift_function(
    text,
    "func mondCurrentSandboxExtensionIssueFile(path: String) -> String? {",
    issue,
)
sbx.write_text(text, encoding="utf-8")

ui = settings.read_text(encoding="utf-8")

old_generate = '''                    Button {
                        token = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) ?? "Failed to get token."
                    } label: {
                        Text("Generate Token")
                    }'''
new_generate = '''                    Button {
                        // The exploit already obtained the MobileGestalt token.
                        // Show that exact token first instead of requiring the
                        // host process to issue a second extension.
                        if let captured = mondCurrentCapturedExploitToken() {
                            token = captured
                            print("(mond) Generate Token loaded captured exploit token (\\(captured.utf8.count) bytes)")
                        } else {
                            token = mondCurrentSandboxExtensionIssueFile(path: MondCurrentTweakPaths.gestalt_dir) ?? "Failed to get token."
                        }
                    } label: {
                        Text("Generate Token")
                    }'''
if old_generate not in ui:
    if new_generate not in ui:
        raise SystemExit("Mond token patch failed: Generate Token button anchor changed")
else:
    ui = ui.replace(old_generate, new_generate, 1)

# grant_mg() is synchronous in upstream grant_all; populate the field as soon
# as the user explicitly presses Run Exploit. PosterBoard work may continue on
# its background queue without affecting the captured MobileGestalt token.
old_run = '''                    Button {
                        grant_all(state: state)
                    } label: {
                        Text("Run Exploit")
                    }'''
new_run = '''                    Button {
                        grant_all(state: state)
                        if let captured = mondCurrentCapturedExploitToken() {
                            token = captured
                            print("(mond) Run Exploit populated captured token (\\(captured.utf8.count) bytes)")
                        }
                    } label: {
                        Text("Run Exploit")
                    }'''
if old_run in ui:
    ui = ui.replace(old_run, new_run, 1)
elif new_run not in ui:
    raise SystemExit("Mond token patch failed: Run Exploit button anchor changed")

# Clear the stale persisted "Failed to get token." state when Settings opens
# after the app-root automatic exploit has already captured a token.
nav = '            .navigationTitle("Settings")\n'
on_appear = '''            .navigationTitle("Settings")
            .onAppear {
                if (token.isEmpty || token == "Failed to get token."),
                   let captured = mondCurrentCapturedExploitToken() {
                    token = captured
                    print("(mond) Settings loaded captured exploit token (\\(captured.utf8.count) bytes)")
                }
            }
'''
if on_appear not in ui:
    if nav not in ui:
        raise SystemExit("Mond token patch failed: Settings navigation title anchor changed")
    ui = ui.replace(nav, on_appear, 1)

settings.write_text(ui, encoding="utf-8")
PY

grep -Fq 'UInt32' "$SBX"
grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0)' "$SBX"
! grep -Fq 'issue("com.apple.app-sandbox.read-write", path, 0, 0)' "$SBX"
grep -Fq 'Generate Token loaded captured exploit token' "$SETTINGS"
grep -Fq 'Run Exploit populated captured token' "$SETTINGS"
grep -Fq 'Settings loaded captured exploit token' "$SETTINGS"

echo "Patched Mond token issuer ABI and token UI without replacing upstream views"
