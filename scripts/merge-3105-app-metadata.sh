#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <Filza.app/Info.plist>" >&2
  exit 64
fi

PLIST="$1"
UPSTREAM="ThirdParty/3105/Resources/Filza3105.bundle/UpstreamAppInfo.plist"
test -f "$PLIST" || { echo "Info.plist not found: $PLIST" >&2; exit 66; }
test -f "$UPSTREAM" || { echo "Staged 3105 metadata not found: $UPSTREAM" >&2; exit 66; }

python3 - "$PLIST" "$UPSTREAM" <<'PY'
import plistlib
import sys

path, upstream_path = sys.argv[1:3]
with open(path, 'rb') as fh:
    info = plistlib.load(fh)
with open(upstream_path, 'rb') as fh:
    upstream = plistlib.load(fh)

patch_uti = 'com.yangjiii.3105.patch-package'
patch_scheme = 'threeoneosfive'

# 3105 is embedded inside Filza; never allow the standalone app metadata merge
# to replace Filza's application identity, release/build numbers, or universal
# deployment target. Only the explicitly merged integration keys below may move.
protected_keys = (
    'CFBundleIdentifier',
    'CFBundleShortVersionString',
    'CFBundleVersion',
    'MinimumOSVersion',
)
protected = {key: info.get(key) for key in protected_keys}

# Preserve Filza's own CFBundleShortVersionString/CFBundleVersion, but expose
# the embedded 3105 release through the custom key its Settings view reads.
release_version = upstream.get('AppReleaseDisplayVersion') or upstream.get('CFBundleShortVersionString')
if not isinstance(release_version, str) or not release_version:
    raise SystemExit('3105 upstream release metadata is missing')
info['AppReleaseDisplayVersion'] = release_version

document_types = list(info.get('CFBundleDocumentTypes') or [])
for entry in upstream.get('CFBundleDocumentTypes') or []:
    if not isinstance(entry, dict):
        continue
    content_types = entry.get('LSItemContentTypes') or []
    if patch_uti in content_types and not any(
        patch_uti in (existing.get('LSItemContentTypes') or [])
        for existing in document_types if isinstance(existing, dict)
    ):
        document_types.append(entry)
info['CFBundleDocumentTypes'] = document_types

url_types = list(info.get('CFBundleURLTypes') or [])
for entry in upstream.get('CFBundleURLTypes') or []:
    if not isinstance(entry, dict):
        continue
    schemes = entry.get('CFBundleURLSchemes') or []
    if patch_scheme in schemes and not any(
        patch_scheme in (existing.get('CFBundleURLSchemes') or [])
        for existing in url_types if isinstance(existing, dict)
    ):
        url_types.append(entry)
info['CFBundleURLTypes'] = url_types

uti_declarations = list(info.get('UTExportedTypeDeclarations') or [])
for entry in upstream.get('UTExportedTypeDeclarations') or []:
    if not isinstance(entry, dict):
        continue
    if entry.get('UTTypeIdentifier') == patch_uti and not any(
        existing.get('UTTypeIdentifier') == patch_uti
        for existing in uti_declarations if isinstance(existing, dict)
    ):
        uti_declarations.append(entry)
info['UTExportedTypeDeclarations'] = uti_declarations
info['LSSupportsOpeningDocumentsInPlace'] = True
info['UIFileSharingEnabled'] = True

# Keep 3105's responsive iPad split-view/landscape navigation metadata without
# replacing the host's iPhone orientation policy.
if upstream.get('UISupportedInterfaceOrientations~ipad'):
    info['UISupportedInterfaceOrientations~ipad'] = upstream['UISupportedInterfaceOrientations~ipad']

for key in ('NSDocumentsFolderUsageDescription', 'NSPhotoLibraryUsageDescription'):
    value = upstream.get(key)
    if isinstance(value, str) and value:
        info.setdefault(key, value)

for key, expected in protected.items():
    if info.get(key) != expected:
        raise SystemExit(
            f'3105 metadata merge attempted to change protected Filza key {key}: '
            f'{expected!r} -> {info.get(key)!r}'
        )

with open(path, 'wb') as fh:
    plistlib.dump(info, fh, fmt=plistlib.FMT_XML, sort_keys=False)
PY

plutil -lint "$PLIST" >/dev/null
plutil -extract CFBundleDocumentTypes xml1 -o - "$PLIST" | grep -Fq 'com.yangjiii.3105.patch-package'
plutil -extract CFBundleURLTypes xml1 -o - "$PLIST" | grep -Fq 'threeoneosfive'
plutil -extract UTExportedTypeDeclarations xml1 -o - "$PLIST" | grep -Fq 'application/x-3105-patch'

EXPECTED_3105_VERSION="$(plutil -extract AppReleaseDisplayVersion raw -o - "$UPSTREAM")"
test -n "$EXPECTED_3105_VERSION"
test "$(plutil -extract AppReleaseDisplayVersion raw -o - "$PLIST")" = "$EXPECTED_3105_VERSION"
plutil -extract UISupportedInterfaceOrientations~ipad xml1 -o - "$PLIST" | grep -Fq 'UIInterfaceOrientationLandscapeLeft'

echo "Merged staged 3105 ${EXPECTED_3105_VERSION} document, URL, version, permission and iPad metadata into $PLIST without changing Filza identity/deployment metadata"
