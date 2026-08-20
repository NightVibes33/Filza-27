#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
UPSTREAM="$ROOT/Upstream"
GEN="$ROOT/Generated/Mond"

EXPECTED_UPSTREAM=(
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
  views/tweaks/mobilegestalt/CEView.swift
  views/tweaks/mobilegestalt/GestaltView.swift
  views/tweaks/SantanderView.swift
  views/tweaks/posterboard/PosterView.swift
  views/tweaks/posterboard/TendiesView.swift
)

# CEView is intentionally merged into the generated Gestalt compilation unit so
# the existing Makefile source graph remains stable across the 2.1 -> 2.2 move.
EXPECTED_GENERATED=(
  exploit_cmg.swift
  exploit_unsbx.swift
  helpers_keepalive.swift
  helpers_mg.swift
  helpers_posterboard_poster.swift
  helpers_posterboard_tendies.swift
  helpers_sbx.swift
  helpers_utils.swift
  views_app_ContentView.swift
  views_app_LogView.swift
  views_app_SettingsView.swift
  views_tweaks_GestaltView.swift
  views_tweaks_SantanderView.swift
  views_tweaks_posterboard_PosterView.swift
  views_tweaks_posterboard_TendiesView.swift
)

actual_file="$(mktemp)"
expected_file="$(mktemp)"
trap 'rm -f "$actual_file" "$expected_file"' EXIT

printf '%s\n' "${EXPECTED_UPSTREAM[@]}" | sort > "$expected_file"
find "$UPSTREAM" -type f -name '*.swift' ! -path "$UPSTREAM/mond.swift" -print \
  | sed "s#^$UPSTREAM/##" \
  | sort > "$actual_file"

if ! diff -u "$expected_file" "$actual_file"; then
  echo "ERROR: pinned Mond 2.2 functional Swift source graph changed." >&2
  echo "Refusing to build with a silently incomplete embedded source list." >&2
  exit 1
fi

for rel in "${EXPECTED_GENERATED[@]}"; do
  test -s "$GEN/$rel" || {
    echo "ERROR: staged Mond 2.2 generated source missing: $GEN/$rel" >&2
    exit 1
  }
done

test -s "$UPSTREAM/exploit/bad_query/bad_query.c"
test -s "$UPSTREAM/exploit/bad_query/bad_query.h"
test -s "$ROOT/Generated/mond_bad_query.c"
test -s "$ROOT/Generated/mond_bad_query.h"

grep -Fq 'MondCurrentCEView' "$GEN/views_tweaks_GestaltView.swift"
grep -Fq 'CacheExtra Fields' "$GEN/views_app_ContentView.swift"
grep -Fq 'Persist after reboot' "$GEN/views_app_SettingsView.swift"
grep -Fq 'Ignore exploit failure' "$GEN/views_app_SettingsView.swift"
grep -Fq 'yK+xavymRGZ3xWc1tb8XDg' "$GEN/helpers_mg.swift"
grep -Fq 'mond=3d91194716ad5f06afdf7e9037e6964e80a4ac29' "$ROOT/PINNED.txt"

echo "Mond 2.2 source completeness verified: ${#EXPECTED_UPSTREAM[@]} functional Swift files + bad_query C bridge"
