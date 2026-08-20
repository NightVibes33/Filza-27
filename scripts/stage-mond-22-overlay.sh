#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
GEN="$ROOT/Generated"
UPSTREAM="$ROOT/Upstream"
MOND_COMMIT="3d91194716ad5f06afdf7e9037e6964e80a4ac29"
PARTYUI_COMMIT="830eaac8ebf8a4cbcec08d49e8746033574d1903"
ZIPFOUNDATION_COMMIT="22787ffb59de99e5dc1fbfe80b19c97a904ad48d"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-mond-2.2.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 \
  "https://codeload.github.com/rooootdev/mond/tar.gz/${MOND_COMMIT}" \
  -o "$TMP/mond.tar.gz"
mkdir -p "$TMP/mond"
tar -xzf "$TMP/mond.tar.gz" -C "$TMP/mond" --strip-components=1

# Replace the provenance copy with the exact current Mond 2.2 tree. PartyUI and
# ZIPFoundation stay on the already-pinned revisions staged by stage-mond-current.sh.
rm -rf "$UPSTREAM"
cp -R "$TMP/mond/mond" "$UPSTREAM"
mkdir -p "$GEN/Mond" "$ROOT/Licenses"

# Keep the historical generated filenames for the existing Makefile source list.
# Upstream moved GestaltView into mobilegestalt/ and added CEView in 2.2; CEView
# is compiled by appending its declarations to the generated Gestalt source.
declare -a SPECS=(
  "exploit/cmg.swift:exploit_cmg.swift"
  "exploit/unsbx.swift:exploit_unsbx.swift"
  "helpers/keepalive.swift:helpers_keepalive.swift"
  "helpers/mg.swift:helpers_mg.swift"
  "helpers/posterboard/poster.swift:helpers_posterboard_poster.swift"
  "helpers/posterboard/tendies.swift:helpers_posterboard_tendies.swift"
  "helpers/sbx.swift:helpers_sbx.swift"
  "helpers/utils.swift:helpers_utils.swift"
  "views/app/ContentView.swift:views_app_ContentView.swift"
  "views/app/LogView.swift:views_app_LogView.swift"
  "views/app/SettingsView.swift:views_app_SettingsView.swift"
  "views/tweaks/mobilegestalt/GestaltView.swift:views_tweaks_GestaltView.swift"
  "views/tweaks/SantanderView.swift:views_tweaks_SantanderView.swift"
  "views/tweaks/posterboard/PosterView.swift:views_tweaks_posterboard_PosterView.swift"
  "views/tweaks/posterboard/TendiesView.swift:views_tweaks_posterboard_TendiesView.swift"
  "views/tweaks/mobilegestalt/CEView.swift:_mond22_CEView.swift"
)

for spec in "${SPECS[@]}"; do
  src="${spec%%:*}"
  dst="${spec#*:}"
  test -s "$UPSTREAM/$src" || {
    echo "Mond 2.2 staging failed: missing upstream source $src" >&2
    exit 1
  }
  cp "$UPSTREAM/$src" "$GEN/Mond/$dst"
done

cp "$UPSTREAM/exploit/bad_query/bad_query.c" "$GEN/mond_bad_query.c"
cp "$UPSTREAM/exploit/bad_query/bad_query.h" "$GEN/mond_bad_query.h"

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
    'TweakToggle': 'MondCurrentTweakToggle',
    'CEView': 'MondCurrentCEView',
    'ce_type': 'MondCurrentCEType',
    'ce_err': 'MondCurrentCEError',
    'CEField': 'MondCurrentCEField',
    'CEEditSheet': 'MondCurrentCEEditSheet',
    'CEAddSheet': 'MondCurrentCEAddSheet',
    'ce_encode': 'mondCurrentCEEncode',
    'ce_parse': 'mondCurrentCEParse',
    'ce_summary': 'mondCurrentCESummary',
    'region_code_key': 'mondCurrentRegionCodeKey',
    'region_info_key': 'mondCurrentRegionInfoKey',
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

def protect_strings_and_comments(text: str, mapping: dict[str, str]) -> str:
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
                    depth += 1; j += 2
                elif text.startswith('*/', j):
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append(text[i:j]); i = j; continue
        if text.startswith('"""', i):
            j = i + 3
            while j < n:
                if text.startswith('"""', j):
                    j += 3; break
                j += 1
            out.append(text[i:j]); i = j; continue
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
                    j += 1; break
                j += 1
            out.append(text[i:j]); i = j; continue
        ch = text[i]
        if ch.isalpha() or ch == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            token = text[i:j]
            out.append(mapping.get(token, token))
            i = j
            continue
        out.append(ch); i += 1
    return ''.join(out)

def rewrite(path: Path):
    text = path.read_text(encoding='utf-8')
    text = re.sub(r'^import\s+(PartyUI|ZIPFoundation)\s*\n', '', text, flags=re.M)
    text = protect_strings_and_comments(text, mond_map)
    for old, new in (
        ('bad_query_release', 'mond_bad_query_release'),
        ('bad_query_list', 'mond_bad_query_list'),
        ('bad_query', 'mond_bad_query'),
    ):
        text = re.sub(rf'\b{old}\b(?=\s*\()', new, text)
    path.write_text(text, encoding='utf-8')

for path in sorted((root / 'Mond').glob('*.swift')):
    rewrite(path)

# Keep Makefile compatibility while compiling the new CacheExtra editor.
gestalt = root / 'Mond/views_tweaks_GestaltView.swift'
ce = root / 'Mond/_mond22_CEView.swift'
gestalt.write_text(
    gestalt.read_text(encoding='utf-8') + '\n\n' + ce.read_text(encoding='utf-8'),
    encoding='utf-8',
)
ce.unlink()

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

cp "$TMP/mond/LICENSE" "$ROOT/Licenses/mond-LICENSE"
cat > "$ROOT/PINNED.txt" <<EOF
mond=$MOND_COMMIT
PartyUI=$PARTYUI_COMMIT
ZIPFoundation=$ZIPFOUNDATION_COMMIT
EOF

# Exact 2.2/current-upstream contract checks. These deliberately fail if a
# future upstream update changes the behavior we think we are embedding.
grep -Fq 'CacheExtra Fields' "$UPSTREAM/views/app/ContentView.swift"
grep -Fq 'Persist after reboot' "$UPSTREAM/views/app/SettingsView.swift"
grep -Fq 'Ignore exploit failure' "$UPSTREAM/views/app/SettingsView.swift"
grep -Fq 'yK+xavymRGZ3xWc1tb8XDg' "$UPSTREAM/helpers/mg.swift"
grep -Fq 'MondCurrentCEView' "$GEN/Mond/views_tweaks_GestaltView.swift"
grep -Fq 'CacheExtra Fields' "$GEN/Mond/views_app_ContentView.swift"
grep -Fq 'Persist after reboot' "$GEN/Mond/views_app_SettingsView.swift"
grep -Fq 'Ignore exploit failure' "$GEN/Mond/views_app_SettingsView.swift"
grep -Fq 'yK+xavymRGZ3xWc1tb8XDg' "$GEN/Mond/helpers_mg.swift"
grep -Fq "mond=$MOND_COMMIT" "$ROOT/PINNED.txt"

echo "Overlayed Mond 2.2/current upstream ${MOND_COMMIT} without changing PartyUI/ZIPFoundation pins"
