#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

# The universal architecture keeps the iOS 16.1 core free of Mond's Swift/C
# implementation so the core never eagerly links the optional module. Mond 2.2
# itself is built separately as FilzaMondModern.dylib with a 16.1 deployment
# target and is loaded by FilzaMondBridge at runtime on every supported OS.
makefile = Path("Makefile")
s = makefile.read_text()

old_c = "FilzaApplySandboxExt_FILES += $(MOND_GEN)/mond_bad_query.c\n"
if old_c not in s:
    raise SystemExit("iOS16 prep: Mond C source anchor missing")
s = s.replace(old_c, "", 1)

old_swift = (
    "FilzaApplySandboxExt_SWIFT_FILES = ByeTunesEmbeddedHost.swift "
    "ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift "
    "FilzaMondCurrentHost.swift Filza3105Host.swift $(MOND_SWIFT_FILES) "
    "$(MOND_PARTYUI_SWIFT_FILES) $(MOND_ZIP_SWIFT_FILES) "
    "$(THREEONE_SWIFT_FILES) $(BYETUNES_SWIFT_FILES) $(BYETUNES_ACTIVITY_SHARED)"
)
new_swift = (
    "FilzaApplySandboxExt_SWIFT_FILES = ByeTunesEmbeddedHost.swift "
    "ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift "
    "Filza3105Host.swift $(THREEONE_SWIFT_FILES) $(BYETUNES_SWIFT_FILES) "
    "$(BYETUNES_ACTIVITY_SHARED)"
)
if old_swift not in s:
    raise SystemExit("iOS16 prep: Swift source anchor missing")
s = s.replace(old_swift, new_swift, 1)

# stage-mond-current.sh proves the pinned Mond source manifest remains represented
# in the build file even though the universal core assignment does not compile it.
marker = "\n# iOS16 universal-core provenance only: $(MOND_SWIFT_FILES)\n"
if marker.strip() not in s:
    s = s.replace(new_swift, new_swift + marker, 1)

makefile.write_text(s)

# Mond routing must remain intact on iOS 16.1+. The bridge lazy-loads the
# separately built FilzaMondModern.dylib and falls back to native Gestalt only if
# that host cannot be loaded. Do not rewrite toolbar/quick-action call sites.
for path, call in (
    (Path("FilzaMainToolbarGestalt.m"), "FilzaMondPresentFromController(controller);"),
    (Path("FilzaQuickActions.m"), "FilzaMondPresentFromController(source);"),
):
    text = path.read_text()
    if call not in text:
        raise SystemExit(f"iOS16 prep: Mond routing anchor missing from {path}")
    if "@available(iOS 17.0" in text and "FilzaGestaltManagerPresentFromController" in text:
        raise SystemExit(f"iOS16 prep: legacy iOS17 Mond gate still present in {path}")
PY

# Fail loudly if a future source change makes the compatibility transform drift.
! grep -Fq 'FilzaMondCurrentHost.swift' <(grep '^FilzaApplySandboxExt_SWIFT_FILES' Makefile)
! grep -Fq '$(MOND_SWIFT_FILES)' <(grep '^FilzaApplySandboxExt_SWIFT_FILES' Makefile)
! grep -Fq '$(MOND_GEN)/mond_bad_query.c' Makefile
grep -Fq '# iOS16 universal-core provenance only: $(MOND_SWIFT_FILES)' Makefile
grep -Fq 'FilzaMondPresentFromController(controller);' FilzaMainToolbarGestalt.m
grep -Fq 'FilzaMondPresentFromController(source);' FilzaQuickActions.m
grep -Fq 'FilzaMondModern.dylib' FilzaMondBridge.m

echo "Prepared iOS 16.1 universal core (Mond routed through lazy universal module)."
