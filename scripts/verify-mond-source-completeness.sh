#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/mond-current"
UPSTREAM="$ROOT/Upstream"
GEN="$ROOT/Generated/Mond"

EXPECTED=(
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

actual_file="$(mktemp)"
expected_file="$(mktemp)"
trap 'rm -f "$actual_file" "$expected_file"' EXIT

printf '%s\n' "${EXPECTED[@]}" | sort > "$expected_file"
find "$UPSTREAM" -type f -name '*.swift' ! -path "$UPSTREAM/mond.swift" -print \
  | sed "s#^$UPSTREAM/##" \
  | sort > "$actual_file"

if ! diff -u "$expected_file" "$actual_file"; then
  echo "ERROR: pinned Mond functional Swift source graph changed." >&2
  echo "Refusing to build with a silently incomplete embedded source list." >&2
  exit 1
fi

for rel in "${EXPECTED[@]}"; do
  generated="$GEN/${rel//\//_}"
  test -s "$generated" || {
    echo "ERROR: staged Mond source missing from generated graph: $rel -> $generated" >&2
    exit 1
  }
done

test -s "$UPSTREAM/exploit/bad_query/bad_query.c"
test -s "$UPSTREAM/exploit/bad_query/bad_query.h"
test -s "$ROOT/Generated/mond_bad_query.c"
test -s "$ROOT/Generated/mond_bad_query.h"

echo "Mond source completeness verified: ${#EXPECTED[@]} functional Swift files + bad_query C bridge"
