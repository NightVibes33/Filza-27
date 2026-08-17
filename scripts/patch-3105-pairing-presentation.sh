#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105/Sources"
CONTENT="$ROOT/ThreeOneOSFiveContentView.swift"

test -f "$CONTENT" || {
  echo "Missing staged 3105 content view: $CONTENT" >&2
  exit 1
}

python3 - "$CONTENT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

state_anchor = "    @State private var showSettings = false\n"
if state_anchor not in text:
    raise SystemExit("3105 pairing presentation patch: showSettings state anchor changed")
text = text.replace(state_anchor, "", 1)

old_toolbar = '''                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(language.text("accessibility.open_settings"))
                }
'''
new_toolbar = '''                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        ThreeOneOSFiveSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(language.text("accessibility.open_settings"))
                }
'''
if old_toolbar not in text:
    raise SystemExit("3105 pairing presentation patch: settings toolbar anchor changed")
text = text.replace(old_toolbar, new_toolbar, 1)

sheet_anchor = "            .sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }\n"
if sheet_anchor not in text:
    raise SystemExit("3105 pairing presentation patch: settings sheet anchor changed")
text = text.replace(sheet_anchor, "", 1)

if "showSettings" in text:
    raise SystemExit("3105 pairing presentation patch: stale showSettings reference remains")
if "NavigationLink {\n                        ThreeOneOSFiveSettingsView()" not in text:
    raise SystemExit("3105 pairing presentation patch: navigation settings route missing")
if ".sheet(isPresented: $showLogs) { LogView() }" not in text:
    raise SystemExit("3105 pairing presentation patch: logs presentation changed unexpectedly")

path.write_text(text, encoding="utf-8")
PY

echo "Patched 3105 Settings to push inside its NavigationStack so the pairing document picker is the only nested modal"
