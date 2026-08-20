#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

# The core Filza fork, 3105, and ByeTunes support iOS 16. Mond does not: its
# pinned upstream app target starts at iOS 17 and its exploit only targets iOS
# 27 beta builds. The iOS 16 variant therefore omits Mond's Swift/C payload but
# keeps the Objective-C bridge ABI so existing Filza call sites remain stable.
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

# stage-mond-current.sh deliberately proves that the pinned Mond source manifest
# is still represented in the build file. Keep that provenance marker even
# though the iOS 16 active source assignment above does not compile Mond.
marker = "\n# iOS16 compatibility provenance only: $(MOND_SWIFT_FILES)\n"
if marker.strip() not in s:
    s = s.replace(new_swift, new_swift + marker, 1)

makefile.write_text(s)

# On iOS 16 the existing Gestalt button/quick action should open Filza's native
# GestaltManager instead of trying to construct the intentionally omitted Mond
# host. iOS 17+ behavior stays untouched.

# Toolbar uses a local variable named controller rather than source.
p = Path("FilzaMainToolbarGestalt.m")
text = p.read_text()
if '#import "GestaltManager.h"' not in text:
    anchor = '#import "FilzaMondBridge.h"\n'
    if anchor not in text:
        raise SystemExit("iOS16 prep: toolbar import anchor missing")
    text = text.replace(anchor, anchor + '#import "GestaltManager.h"\n', 1)
call = '    FilzaMondPresentFromController(controller);'
if call not in text:
    raise SystemExit("iOS16 prep: toolbar Mond call anchor missing")
text = text.replace(
    call,
    '    if (@available(iOS 17.0, *)) {\n'
    '        FilzaMondPresentFromController(controller);\n'
    '    } else {\n'
    '        FilzaGestaltManagerPresentFromController(controller);\n'
    '    }',
    1,
)
p.write_text(text)

# Home Screen quick action has a source variable and should use the same route.
p = Path("FilzaQuickActions.m")
text = p.read_text()
if '#import "GestaltManager.h"' not in text:
    anchor = '#import "FilzaMondBridge.h"\n'
    if anchor not in text:
        raise SystemExit("iOS16 prep: quick-action import anchor missing")
    text = text.replace(anchor, anchor + '#import "GestaltManager.h"\n', 1)
call = '            FilzaMondPresentFromController(source);'
if call not in text:
    raise SystemExit("iOS16 prep: quick-action Mond call anchor missing")
text = text.replace(
    call,
    '            if (@available(iOS 17.0, *)) {\n'
    '                FilzaMondPresentFromController(source);\n'
    '            } else {\n'
    '                FilzaGestaltManagerPresentFromController(source);\n'
    '            }',
    1,
)
p.write_text(text)
PY

# Fail loudly if a future source change makes the compatibility transform drift.
! grep -Fq 'FilzaMondCurrentHost.swift' <(grep '^FilzaApplySandboxExt_SWIFT_FILES' Makefile)
! grep -Fq '$(MOND_SWIFT_FILES)' <(grep '^FilzaApplySandboxExt_SWIFT_FILES' Makefile)
! grep -Fq '$(MOND_GEN)/mond_bad_query.c' Makefile
grep -Fq '# iOS16 compatibility provenance only: $(MOND_SWIFT_FILES)' Makefile
grep -Fq 'FilzaGestaltManagerPresentFromController(controller)' FilzaMainToolbarGestalt.m
grep -Fq 'FilzaGestaltManagerPresentFromController(source)' FilzaQuickActions.m

echo "Prepared iOS 16 compatibility source graph (Mond manifest preserved; native Gestalt route active)."
