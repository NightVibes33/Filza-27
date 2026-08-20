#!/usr/bin/env bash
set -euo pipefail

UTILS="ThirdParty/3105/Sources/Utils.swift"
test -f "$UTILS" || { echo "Missing staged 3105 Utils.swift" >&2; exit 1; }

python3 - "$UTILS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# 3105 1.1.1's standalone app links DisplayIdentityAttribution.swift and calls
# the attestation token from AppInfo. Filza intentionally does not install that
# standalone attribution/window hook into its process. Preserve the normal
# hardware-name mapping while removing only the unused attestation side effect.
attestation_block = '''        // Validate display-identity attestation at first access; keeps
        // DisplayIdentity linked. Looks like a license/attestation check.
        _ = DisplayIdentityAttestationToken()
'''
if attestation_block not in text:
    raise SystemExit("3105 embedded compat: DisplayIdentity attestation anchor changed")
text = text.replace(attestation_block, "", 1)

launch_token = '''    static var launchAttestationToken: String { DisplayIdentityAttestationToken() }
'''
if launch_token not in text:
    raise SystemExit("3105 embedded compat: launchAttestationToken anchor changed")
text = text.replace(launch_token, "", 1)

# AppUpdateChecker is consumed only by upstream's standalone App.swift, which is
# not compiled inside Filza. ByeTunes already has an AppUpdateChecker in the
# same Swift module, so retaining this unused standalone type causes a global
# symbol/type redeclaration. The embedded workspace has no references to it.
marker = "\nenum AppUpdateChecker {\n"
idx = text.find(marker)
if idx < 0:
    raise SystemExit("3105 embedded compat: AppUpdateChecker anchor changed")
text = text[:idx].rstrip() + "\n"

if "DisplayIdentityAttestationToken" in text:
    raise SystemExit("3105 embedded compat: DisplayIdentity reference still present")
if "enum AppUpdateChecker" in text:
    raise SystemExit("3105 embedded compat: standalone AppUpdateChecker still present")

path.write_text(text, encoding="utf-8")
PY

grep -Fq 'enum AppInfo' "$UTILS"
grep -Fq 'static var hardwareDisplayName' "$UTILS"
grep -Fq 'enum ExploitStatus' "$UTILS"
grep -Fq 'enum AppPaths' "$UTILS"
! grep -Fq 'DisplayIdentityAttestationToken' "$UTILS"
! grep -Fq 'enum AppUpdateChecker' "$UTILS"

echo "Applied 3105 1.1.1 embedded-host compatibility transform (standalone updater/attestation excluded)"
