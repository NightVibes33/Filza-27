#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
GEN="$ROOT/Generated"
UPSTREAM="$ROOT/Upstream"
MOND_COMMIT="87b38b2726160c6d1cfacbbfa834a2572d7ca333"
PARTYUI_COMMIT="830eaac8ebf8a4cbcec08d49e8746033574d1903"
ZIPFOUNDATION_COMMIT="22787ffb59de99e5dc1fbfe80b19c97a904ad48d"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-mond-2.0.XXXXXX")"
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

rm -rf "$GEN" "$UPSTREAM"
mkdir -p "$GEN/Mond" "$GEN/PartyUI" "$GEN/ZIPFoundation" "$ROOT/Licenses"

# Keep an untouched copy of the complete upstream 2.0 app source tree for
# provenance. Only Generated/ is mechanically adapted for compilation inside
# Filza's existing UIApplication/module.
cp -R "$TMP/mond/mond" "$UPSTREAM"

MOND_FILES=(
  exploit/cmg.swift
  exploit/unsbx.swift
  helpers/keepalive.swift
  helpers/mg.swift
  helpers/posterboard/poster.swift
  helpers/posterboard/tendies.swift
  helpers/sbx.swift
  helpers/utils.swift
  views/app/ContentView.swift
  views/app/LogView.swift
  views/app/SettingsView.swift
  views/tweaks/GestaltView.swift
  views/tweaks/SantanderView.swift
  views/tweaks/posterboard/PosterView.swift
  views/tweaks/posterboard/TendiesView.swift
)

for rel in "${MOND_FILES[@]}"; do
  test -f "$UPSTREAM/$rel" || { echo "Missing Mond 2.0 source: $rel" >&2; exit 1; }
  dest="$GEN/Mond/${rel//\//_}"
  cp "$UPSTREAM/$rel" "$dest"
done

cp "$UPSTREAM/exploit/bad_query/bad_query.c" "$GEN/mond_bad_query.c"
cp "$UPSTREAM/exploit/bad_query/bad_query.h" "$GEN/mond_bad_query.h"

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

# These are module-collision adaptations only. The untouched Mond 2.0 source is
# retained under ThirdParty/mond-current/Upstream and no behavioral/UI patch is
# applied to it or to the generated copy.
mond_map = {
    'ContentView': 'MondCurrentContentView',
    'AppState': 'MondCurrentAppState',
    'LogView': 'MondCurrentLogView',
    'SettingsView': 'MondCurrentSettingsView',
    'CreditsRow': 'MondCurrentCreditsRow',
    'GestaltView': 'MondCurrentGestaltView',
    'TweakToggle': 'MondCurrentTweakToggle',
    'PosterView': 'MondCurrentPosterView',
    'TendiesView': 'MondCurrentTendiesView',
    'TendiesDetail': 'MondCurrentTendiesDetail',
    'TendiesVM': 'MondCurrentTendiesVM',
    'tendies_service': 'MondCurrentTendiesService',
    'tendies': 'MondCurrentTendies',
    'SafariView': 'MondCurrentSafariView',
    'SantanderPath': 'MondCurrentSantanderPath',
    'SantanderView': 'MondCurrentSantanderView',
    'SantanderDirectoryView': 'MondCurrentSantanderDirectoryView',
    'SantanderFileView': 'MondCurrentSantanderFileView',
    'MediaPlayerView': 'MondCurrentMediaPlayerView',
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

def protect_strings_and_comments(text: str, mapping: dict[str, str]) -> str:
    """Rename Swift identifiers without changing string/comment contents."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            if end < 0:
                out.append(text[i:])
                break
            out.append(text[i:end + 1])
            i = end + 1
            continue

        if text.startswith('/*', i):
            depth = 1
            j = i + 2
            while j < n and depth:
                if text.startswith('/*', j):
                    depth += 1
                    j += 2
                elif text.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(text[i:j])
            i = j
            continue

        if text.startswith('"""', i):
            j = i + 3
            while j < n:
                if text.startswith('"""', j):
                    j += 3
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue

        if text[i] == '"':
            j = i + 1
            escaped = False
            while j < n:
                ch = text[j]
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == '"':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue

        ch = text[i]
        if ch.isalpha() or ch == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            token = text[i:j]
            out.append(mapping.get(token, token))
            i = j
            continue

        out.append(ch)
        i += 1
    return ''.join(out)

def rewrite(path: Path, mapping: dict[str, str], strip_imports=()):
    text = path.read_text(encoding='utf-8')
    for module in strip_imports:
        text = re.sub(rf'^import\s+{re.escape(module)}\s*\n', '', text, flags=re.M)
    text = protect_strings_and_comments(text, mapping)

    # bad_query is also a user-visible method/tag string. Namespace only actual
    # C/Swift symbol calls, never the string value "bad_query".
    for old, new in (
        ('bad_query_release', 'mond_bad_query_release'),
        ('bad_query_list', 'mond_bad_query_list'),
        ('bad_query', 'mond_bad_query'),
    ):
        text = re.sub(rf'\b{old}\b(?=\s*\()', new, text)

    path.write_text(text, encoding='utf-8')

for path in sorted((root / 'Mond').glob('*.swift')):
    rewrite(path, mond_map, strip_imports=('PartyUI', 'ZIPFoundation'))
for path in sorted((root / 'PartyUI').glob('*.swift')):
    rewrite(path, party_map)
for path in sorted((root / 'ZIPFoundation').glob('*.swift')):
    rewrite(path, zip_map)

for name in ('mond_bad_query.c', 'mond_bad_query.h'):
    path = root / name
    text = path.read_text(encoding='utf-8')
    for old, new in (
        ('bad_query_release', 'mond_bad_query_release'),
        ('bad_query_list', 'mond_bad_query_list'),
        ('bad_query', 'mond_bad_query'),
    ):
        text = re.sub(rf'\b{old}\b(?=\s*\()', new, text)
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
    echo "Mond 2.0 staging check failed: ${label} marker '${marker}' missing from ${path}" >&2
    exit 1
  }
}

# Prove the full upstream 2.0 surface is staged.
require_contains "$UPSTREAM/mond.swift" 'grant_all(state: state)' 'upstream automatic exploit lifecycle'
require_contains "$UPSTREAM/views/app/SettingsView.swift" 'Your sandbox token is invalid.' 'upstream token validation UI'
require_contains "$UPSTREAM/views/app/SettingsView.swift" '.onChange(of: ka_on) { _, enabled in' 'upstream iOS 17 Keep Alive form'
require_contains "$UPSTREAM/views/tweaks/posterboard/PosterView.swift" '"Explore Tendies"' 'Tendies explorer'
require_contains "$UPSTREAM/views/tweaks/posterboard/TendiesView.swift" 'struct TendiesView' 'Tendies UI'
require_contains "$UPSTREAM/helpers/posterboard/tendies.swift" '@Observable' 'Tendies model'
require_contains "$UPSTREAM/views/tweaks/SantanderView.swift" 'struct SantanderView' 'HouseArrest browser'
require_contains "$UPSTREAM/helpers/mg.swift" 'Security Research Device Mode' 'Mond 2.0 MobileGestalt catalog'

# Prove the mechanically namespaced copy still contains those exact behaviors.
require_contains "$GEN/Mond/views_app_ContentView.swift" 'navigationTitle("mond")' 'root title'
require_contains "$GEN/Mond/views_app_ContentView.swift" 'MondCurrentTerminalPlatter' 'terminal UI'
require_contains "$GEN/Mond/views_app_ContentView.swift" '"MobileGestalt"' 'MobileGestalt route'
require_contains "$GEN/Mond/views_app_ContentView.swift" '"PosterBoard"' 'PosterBoard route'
require_contains "$GEN/Mond/views_app_ContentView.swift" '"HouseArrest"' 'HouseArrest route'
require_contains "$GEN/Mond/views_app_SettingsView.swift" '"Run Exploit"' 'Run Exploit action'
require_contains "$GEN/Mond/views_app_SettingsView.swift" '"Generate Token"' 'Generate Token action'
require_contains "$GEN/Mond/views_app_SettingsView.swift" 'Your sandbox token is invalid.' 'upstream token validation UI'
require_contains "$GEN/Mond/views_app_SettingsView.swift" '.onChange(of: ka_on) { _, enabled in' 'upstream iOS 17 Keep Alive form'
require_contains "$GEN/Mond/helpers_sbx.swift" 'issue("com.apple.app-sandbox.read-write", path, 0, 0)' 'upstream SandboxSPI call'
require_contains "$GEN/Mond/views_tweaks_posterboard_PosterView.swift" '"Explore Tendies"' 'Tendies explorer'
require_contains "$GEN/Mond/views_tweaks_posterboard_TendiesView.swift" 'struct MondCurrentTendiesView' 'Tendies UI'
require_contains "$GEN/Mond/helpers_posterboard_tendies.swift" '@Observable' 'Tendies model'
require_contains "$GEN/Mond/views_tweaks_SantanderView.swift" 'struct MondCurrentSantanderView' 'HouseArrest browser'
require_contains "$GEN/mond_bad_query.c" 'mond_bad_query' 'namespaced Mond bad_query'
require_contains "$GEN/ZIPFoundation/Entry.swift" 'public struct MondZIPEntry' 'namespaced ZIPFoundation Entry'

# There must be no old Filza-only Mond behavior patches in the staging path.
! grep -R -Fq 'FILZA_IOS27_GESTALT_KEYS_BEGIN' "$GEN/Mond"
! grep -R -Fq 'lastFreshToken' "$GEN/Mond"
! grep -R -Fq 'Fresh sandbox token issued successfully. Mond has not consumed it.' "$GEN/Mond"
! grep -R -Fq 'Color(red: 0.28529, green: 0.44118, blue: 0.92451)' "$GEN/Mond"

require_contains Makefile '$(MOND_SWIFT_FILES)' 'Mond source graph in build'
require_contains FilzaMondCurrentHost.swift 'grant_all(state: state)' 'upstream automatic onAppear behavior'
require_contains FilzaMondBridge.m 'full Mond 2.0 route installed commit=87b38b2726160c6d1cfacbbfa834a2572d7ca333' 'Mond 2.0 bridge provenance'

ZIP_SWIFT_COUNT="$(find "$GEN/ZIPFoundation" -type f -name '*.swift' | wc -l | tr -d ' ')"
test "$ZIP_SWIFT_COUNT" -ge 20 || {
  echo "Mond 2.0 staging check failed: expected >=20 ZIPFoundation Swift sources, got $ZIP_SWIFT_COUNT" >&2
  exit 1
}

echo "Staged exact Mond 2.0 ${MOND_COMMIT} with PartyUI ${PARTYUI_COMMIT} and ZIPFoundation ${ZIPFOUNDATION_COMMIT}; no Filza behavior/UI patches applied"
