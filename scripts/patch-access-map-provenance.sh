#!/bin/bash
set -euo pipefail

TARGET="MCMFilzaIntegration.m"
test -f "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()


def replace_exact(old: str, new: str, label: str, expected_count: int = 1) -> None:
    global text
    if new in text and old not in text:
        return
    count = text.count(old)
    if count != expected_count:
        raise SystemExit(f"{label}: expected {expected_count} old anchor(s), found {count}")
    text = text.replace(old, new, expected_count)


# The device/build at the top is runtime-derived. Keep cross-build observations
# explicitly historical so a report generated on 24A5380h cannot call 24A5390f
# the current build (and vice versa).
replace_exact(
    '         "Build-specific proof is labeled below. The current device is %@.\\n"\n',
    '         "Current launch: %@.\\n"\n'
    '         "Recorded cross-build observations are labeled by measured build and are not presented as current-launch results.\\n"\n',
    "runtime provenance header",
)

# Preserve the recorded evidence, but never present a different measured build
# as the current launch. The negative control gets its own label.
replace_exact(
    '         "Current 24A5390f proof: raw containermanagerd command 39 rejected MobileHouseArrest, mobile_installation_proxy, filecoordinationd, accountsd, and Safari.History identities. No reply contained a container path or sandbox token.\\n\\n"\n',
    '         "Recorded negative-control result on build 24A5390f: raw containermanagerd command 39 rejected MobileHouseArrest, mobile_installation_proxy, filecoordinationd, accountsd, and Safari.History identities. No reply contained a container path or sandbox token.\\n\\n"\n',
    "ProxyForClient negative-control provenance",
)

old_current = "Current 24A5390f proof:"
new_current = "Recorded proof on build 24A5390f:"
if new_current not in text or old_current in text:
    count = text.count(old_current)
    if count != 2:
        raise SystemExit(f"recorded 24A5390f proof provenance: expected 2 anchors, found {count}")
    text = text.replace(old_current, new_current)

old_archived = "Archived 24A5380h proof:"
new_archived = "Recorded controlled-write proof on build 24A5380h:"
if new_archived not in text or old_archived in text:
    count = text.count(old_archived)
    if count != 2:
        raise SystemExit(f"recorded 24A5380h write provenance: expected 2 anchors, found {count}")
    text = text.replace(old_archived, new_archived)

replace_exact(
    "Current 24A5390f boundary:",
    "Recorded boundary on build 24A5390f:",
    "recorded 24A5390f boundary provenance",
)

# ACCESS MAP previously overstated what its live fields prove. In the current
# implementation, Readable/Writable are access(2) checks and ReadOnlyOpen is an
# O_RDONLY open. A visible scoped symlink also does not, by itself, prove that
# sandbox_extension_consume succeeded. State those semantics directly.
old_live_block = (
    '         "Current Filza access\\n"\n'
    '         "The sections below are generated during the current launch.\\n"\n'
    '         "Only direct symlinks created after token activation and a directory-open check appear as enabled roots.\\n"\n'
    '         "Experimental sections also show each checked subpath and its current open status.\\n\\n"];' 
)
new_live_block = (
    '         "Current-launch Filza access\\n"\n'
    '         "The sections below are generated during the current launch on the runtime build shown above.\\n"\n'
    '         "Enabled roots are symlinks whose MCM-returned directory passed the code\'s read-only directory-open gate; this line alone is not a claim that sandbox_extension_consume succeeded.\\n"\n'
    '         "Experimental status=linked means a symlink was installed after the scoped lookup returned a directory that passed the read-only open gate.\\n"\n'
    '         "Probe semantics: readable/writable are access(R_OK/W_OK) checks; open=yes means an O_RDONLY open succeeded. These fields do not claim an actual target write.\\n"\n'
    '         "Actual mutation is claimed only where a separately labeled controlled-write proof explicitly says bytes were written, verified, and restored.\\n\\n"];' 
)
replace_exact(old_live_block, new_live_block, "current-launch proof semantics")

path.write_text(text)
PY

# Fail closed if a future source change reintroduces ambiguous cross-build
# wording or removes the current-launch proof legend.
! grep -Fq 'Current 24A5390f proof:' "$TARGET"
! grep -Fq 'Current 24A5390f boundary:' "$TARGET"
! grep -Fq 'Archived 24A5380h proof:' "$TARGET"
grep -Fq 'Current launch: %@.' "$TARGET"
grep -Fq 'Recorded proof on build 24A5390f:' "$TARGET"
grep -Fq 'Recorded controlled-write proof on build 24A5380h:' "$TARGET"
grep -Fq 'Recorded negative-control result on build 24A5390f:' "$TARGET"
grep -Fq 'readable/writable are access(R_OK/W_OK) checks' "$TARGET"
grep -Fq 'These fields do not claim an actual target write.' "$TARGET"

# Keep the on-device Music library mutation hardening in the same fail-closed
# pre-build chain so every produced IPA gets persistence verification.
bash scripts/patch-byetunes-device-library-save.sh

# Make the visible Import Metadata Source picker authoritative before the
# metadata-compatibility source is compiled. This prevents stale pre-v2.4
# metadataSourcesJSON state from silently turning Local Files into All Sources.
bash scripts/fix-byetunes-import-source-routing.sh
