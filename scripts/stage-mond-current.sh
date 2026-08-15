#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
GEN="$ROOT/Generated"
MOND_COMMIT="4a37bfca5cb4abb2c99891972365d872d700525e"
PARTYUI_COMMIT="830eaac8ebf8a4cbcec08d49e8746033574d1903"
ZIPFOUNDATION_COMMIT="22787ffb59de99e5dc1fbfe80b19c97a904ad48d"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-mond-current.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fetch_archive() {
  local owner="$1" repo="$2" commit="$3" out="$4"
  curl -fL --retry 3 --retry-delay 2 \
    "https://codeload.github.com/${owner}/${repo}/tar.gz/${commit}" -o "$out"
}

fetch_archive rooootdev mond "$MOND_COMMIT" "$TMP/mond.tar.gz"
fetch_archive jailbreakdotparty PartyUI "$PARTYUI_COMMIT" "$TMP/partyui.tar.gz"
fetch_archive weichsel ZIPFoundation "$ZIPFOUNDATION_COMMIT" "$TMP/zipfoundation.tar.gz"

mkdir -p "$TMP/mond" "$TMP/partyui" "$TMP/zipfoundation"
tar -xzf "$TMP/mond.tar.gz" -C "$TMP/mond" --strip-components=1
tar -xzf "$TMP/partyui.tar.gz" -C "$TMP/partyui" --strip-components=1
tar -xzf "$TMP/zipfoundation.tar.gz" -C "$TMP/zipfoundation" --strip-components=1

rm -rf "$GEN"
mkdir -p "$GEN/Mond" "$GEN/PartyUI" "$GEN/ZIPFoundation" "$ROOT/Licenses"

MOND_FILES=(
  exploit/cmg.swift
  exploit/unsbx.swift
  helpers/keepalive.swift
  helpers/mg.swift
  helpers/poster.swift
  helpers/sbx.swift
  helpers/utils.swift
  views/App/ContentView.swift
  views/App/LogView.swift
  views/App/SettingsView.swift
  views/Tweaks/GestaltView.swift
  views/Tweaks/PosterView.swift
  views/Tweaks/SantanderView.swift
)

for rel in "${MOND_FILES[@]}"; do
  test -f "$TMP/mond/mond/$rel" || { echo "Missing mond source: $rel" >&2; exit 1; }
  dest="$GEN/Mond/${rel//\//_}"
  cp "$TMP/mond/mond/$rel" "$dest"
done

cp "$TMP/mond/mond/exploit/bad_query/bad_query.c" "$GEN/mond_bad_query.c"
cp "$TMP/mond/mond/exploit/bad_query/bad_query.h" "$GEN/mond_bad_query.h"

PARTY_FILES=(
  Containers/TerminalPlatter.swift
  Alerts/PlainAlert.swift
  Toggles/PlainToggle.swift
  Toggles/PlatterToggle.swift
  Utilities/Alertinator.swift
  Utilities/Helpers.swift
  Buttons/TranslucentButtonStyle.swift
)
for rel in "${PARTY_FILES[@]}"; do
  test -f "$TMP/partyui/Sources/PartyUI/$rel" || { echo "Missing PartyUI source: $rel" >&2; exit 1; }
  cp "$TMP/partyui/Sources/PartyUI/$rel" "$GEN/PartyUI/${rel//\//_}"
done

while IFS= read -r src; do
  cp "$src" "$GEN/ZIPFoundation/$(basename "$src")"
done < <(find "$TMP/zipfoundation/Sources/ZIPFoundation" -maxdepth 1 -type f -name '*.swift' -print | sort)

python3 - "$GEN" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

mond_map = {
    'ContentView': 'MondCurrentContentView',
    'AppState': 'MondCurrentAppState',
    'LogView': 'MondCurrentLogView',
    'SettingsView': 'MondCurrentSettingsView',
    'CreditsRow': 'MondCurrentCreditsRow',
    'GestaltView': 'MondCurrentGestaltView',
    'PosterView': 'MondCurrentPosterView',
    'SafariView': 'MondCurrentSafariView',
    'AppPaths': 'MondCurrentAppPaths',
    'TweakPaths': 'MondCurrentTweakPaths',
    'RespringView': 'MondCurrentRespringView',
    'Alertinator': 'MondCurrentAlertinator',
    'TerminalPlatter': 'MondCurrentTerminalPlatter',
    'PlainAlert': 'MondCurrentPlainAlert',
    'PlainToggle': 'MondCurrentPlainToggle',
    'ToggleInfoType': 'MondCurrentToggleInfoType',
    'doubleSystemVersion': 'mondCurrentSystemVersion',
    'sandbox_extension_consume': 'mondCurrentSandboxExtensionConsume',
    'sandbox_extension_issue_file': 'mondCurrentSandboxExtensionIssueFile',
    'bad_query_release': 'mond_bad_query_release',
    'bad_query_list': 'mond_bad_query_list',
    'bad_query': 'mond_bad_query',
    'pb_error': 'MondCurrentPosterError',
    'pb': 'MondCurrentPosterBackend',
}

party_map = {
    'TerminalPlatter': 'MondCurrentTerminalPlatter',
    'PlainAlert': 'MondCurrentPlainAlert',
    'PlainToggle': 'MondCurrentPlainToggle',
    'PlatterToggle': 'MondCurrentPlatterToggle',
    'ToggleInfoType': 'MondCurrentToggleInfoType',
    'Alertinator': 'MondCurrentAlertinator',
    'TranslucentButtonStyle': 'MondCurrentTranslucentButtonStyle',
    'cornerRad': 'MondCurrentCornerRad',
    'AppInfo': 'MondCurrentPartyAppInfo',
    'doubleSystemVersion': 'mondCurrentSystemVersion',
}

zip_map = {'Entry': 'MondZIPEntry'}

def rewrite(path: Path, mapping: dict[str, str], strip_imports=()):
    text = path.read_text(encoding='utf-8')
    for module in strip_imports:
        text = re.sub(rf'^import\s+{re.escape(module)}\s*\n', '', text, flags=re.M)
    for old in sorted(mapping, key=len, reverse=True):
        text = re.sub(rf'\b{re.escape(old)}\b', mapping[old], text)
    path.write_text(text, encoding='utf-8')

for path in sorted((root / 'Mond').glob('*.swift')):
    rewrite(path, mond_map, strip_imports=('PartyUI', 'ZIPFoundation'))
for path in sorted((root / 'PartyUI').glob('*.swift')):
    rewrite(path, party_map)
for path in sorted((root / 'ZIPFoundation').glob('*.swift')):
    rewrite(path, zip_map)

settings = root / 'Mond' / 'views_App_SettingsView.swift'
settings_text = settings.read_text(encoding='utf-8')
old_on_change = '.onChange(of: ka_on) { _, enabled in'
new_on_change = '.onChange(of: ka_on) { enabled in'
if old_on_change not in settings_text:
    raise SystemExit('Current mond staging check failed: expected Keep Alive iOS 17 onChange form not found')
settings.write_text(settings_text.replace(old_on_change, new_on_change, 1), encoding='utf-8')

for name in ('mond_bad_query.c', 'mond_bad_query.h'):
    path = root / name
    text = path.read_text(encoding='utf-8')
    for old, new in (
        ('bad_query_release', 'mond_bad_query_release'),
        ('bad_query_list', 'mond_bad_query_list'),
        ('bad_query', 'mond_bad_query'),
    ):
        text = re.sub(rf'\b{old}\b', new, text)
    text = text.replace('bad_query_h', 'mond_bad_query_h')
    path.write_text(text, encoding='utf-8')
PY

for spec in \
  "$TMP/mond/LICENSE:$ROOT/Licenses/mond-LICENSE" \
  "$TMP/partyui/LICENSE:$ROOT/Licenses/PartyUI-LICENSE" \
  "$TMP/zipfoundation/LICENSE:$ROOT/Licenses/ZIPFoundation-LICENSE"; do
  src="${spec%%:*}"; dst="${spec#*:}"
  if test -f "$src"; then cp "$src" "$dst"; fi
done

cat > "$ROOT/PINNED.txt" <<EOF
mond=$MOND_COMMIT
PartyUI=$PARTYUI_COMMIT
ZIPFoundation=$ZIPFOUNDATION_COMMIT
EOF

require_contains() {
  local path="$1" marker="$2" label="$3"
  grep -Fq "$marker" "$path" || {
    echo "Current mond staging check failed: ${label} marker '${marker}' missing from ${path}" >&2
    exit 1
  }
}

require_contains "$GEN/Mond/views_App_ContentView.swift" 'navigationTitle("mond")' 'root title'
require_contains "$GEN/Mond/views_App_ContentView.swift" 'MondCurrentTerminalPlatter' 'real terminal platter'
require_contains "$GEN/Mond/views_App_ContentView.swift" '"MobileGestalt"' 'MobileGestalt route'
require_contains "$GEN/Mond/views_App_ContentView.swift" '"PosterBoard"' 'PosterBoard route'
require_contains "$GEN/Mond/views_App_ContentView.swift" '"HouseArrest"' 'current HouseArrest route'
require_contains "$GEN/Mond/views_App_SettingsView.swift" '"Run Exploit"' 'exploit action'
require_contains "$GEN/Mond/views_App_SettingsView.swift" '"Generate Token"' 'token action'
require_contains "$GEN/Mond/views_App_SettingsView.swift" '"Keep Alive"' 'keep-alive setting'
require_contains "$GEN/Mond/views_App_SettingsView.swift" '.onChange(of: ka_on) { enabled in' 'iOS 16 Keep Alive onChange compatibility'
require_contains "$GEN/Mond/views_App_SettingsView.swift" '"Respring"' 'respring action'
require_contains "$GEN/Mond/helpers_sbx.swift" 'func mondCurrentSandboxExtensionConsume' 'namespaced sandbox consume helper'
require_contains "$GEN/Mond/helpers_sbx.swift" 'func mondCurrentSandboxExtensionIssueFile' 'namespaced sandbox issue helper'
require_contains "$GEN/Mond/views_Tweaks_SantanderView.swift" 'struct SantanderView' 'current Santander view'
require_contains "$GEN/mond_bad_query.c" 'mond_bad_query' 'namespaced mond bad_query'
require_contains "$GEN/ZIPFoundation/Entry.swift" 'public struct MondZIPEntry' 'namespaced ZIPFoundation Entry type'

require_contains Makefile 'FilzaMondCurrentHost.swift' 'current mond host in Swift build graph'
require_contains Makefile '$(MOND_SWIFT_FILES)' 'current mond upstream sources in Swift build graph'
require_contains Makefile '$(MOND_PARTYUI_SWIFT_FILES)' 'current mond PartyUI sources in Swift build graph'
require_contains Makefile '$(MOND_ZIP_SWIFT_FILES)' 'current mond ZIPFoundation sources in Swift build graph'
require_contains FilzaMondCurrentHost.swift '@objc(MondEmbeddedHostFactory)' 'full mond host factory'
require_contains FilzaMondCurrentHost.swift 'MondCurrentContentView()' 'current mond root hosted by Filza'
require_contains MondFullRootHost.swift 'current mond compatibility shim' 'retired custom root replaced by forwarding shim'
require_contains FilzaMondBridge.m 'full current mond route installed commit=4a37bfca5cb4abb2c99891972365d872d700525e' 'full mond bridge route'
require_contains scripts/patch-mond-ios27-keys.sh 'FILZA_IOS27_GESTALT_KEYS_BEGIN' 'iOS 27 Mond overlay patch'
require_contains MondIOS27KeySupport.swift 'DeviceSupportsInstructionFollowingPruningModels' 'iOS 27 key support table'

if grep -Fq 'MondGestaltView.swift' Makefile; then
  echo "Current mond staging check failed: retired MondGestaltView.swift is back in the build graph" >&2
  exit 1
fi
if grep -Fq 'struct MondEmbeddedLogView' MondFullRootHost.swift; then
  echo "Current mond staging check failed: hand-built MondFullRootHost UI is back" >&2
  exit 1
fi
if grep -Fq 'FilzaGestaltResolvePath' FilzaMondBridge.m; then
  echo "Current mond staging check failed: bridge still pre-gates presentation on MobileGestalt" >&2
  exit 1
fi
if grep -Fq '.onChange(of: ka_on) { _, enabled in' "$GEN/Mond/views_App_SettingsView.swift"; then
  echo "Current mond staging check failed: iOS 17-only Keep Alive onChange form survived adaptation" >&2
  exit 1
fi
if grep -Fq 'public struct Entry' "$GEN/ZIPFoundation/Entry.swift"; then
  echo "Current mond staging check failed: unnamespaced ZIPFoundation Entry survived adaptation" >&2
  exit 1
fi

ZIP_SWIFT_COUNT="$(find "$GEN/ZIPFoundation" -type f -name '*.swift' | wc -l | tr -d ' ')"
test "$ZIP_SWIFT_COUNT" -ge 20 || {
  echo "Current mond staging check failed: expected >=20 ZIPFoundation Swift sources, got $ZIP_SWIFT_COUNT" >&2
  exit 1
}

# Layer the project-specific iOS 27 key editor and Mond asset-color parity onto
# the freshly staged immutable upstream source. The patch aborts if upstream's
# structural anchor changes instead of silently building a partial Mond port.
bash scripts/patch-mond-ios27-keys.sh

require_contains "$GEN/Mond/views_Tweaks_GestaltView.swift" 'FILZA_IOS27_GESTALT_KEYS_BEGIN' 'compiled iOS 27 key section'
require_contains "$GEN/Mond/views_Tweaks_GestaltView.swift" 'DeviceSupportsHighLuminanceAlwaysOnDisplay' 'compiled iOS 27 keys'

echo "Staged current mond ${MOND_COMMIT} with PartyUI ${PARTYUI_COMMIT} and ZIPFoundation ${ZIPFOUNDATION_COMMIT}"