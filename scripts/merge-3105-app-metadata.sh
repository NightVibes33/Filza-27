#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 <Filza.app/Info.plist>" >&2
  exit 64
fi

PLIST="$1"
test -f "$PLIST" || { echo "Info.plist not found: $PLIST" >&2; exit 66; }

python3 - "$PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, 'rb') as fh:
    info = plistlib.load(fh)

patch_uti = 'com.yangjiii.3105.patch-package'
patch_scheme = 'threeoneosfive'

document_types = list(info.get('CFBundleDocumentTypes') or [])
if not any(patch_uti in (entry.get('LSItemContentTypes') or []) for entry in document_types if isinstance(entry, dict)):
    document_types.append({
        'CFBundleTypeName': '3105 Patch Package',
        'CFBundleTypeRole': 'Editor',
        'LSHandlerRank': 'Owner',
        'LSItemContentTypes': [patch_uti],
    })
info['CFBundleDocumentTypes'] = document_types

url_types = list(info.get('CFBundleURLTypes') or [])
if not any(patch_scheme in (entry.get('CFBundleURLSchemes') or []) for entry in url_types if isinstance(entry, dict)):
    url_types.append({
        'CFBundleURLName': 'com.yangjiii.3105.patch-import',
        'CFBundleURLSchemes': [patch_scheme],
    })
info['CFBundleURLTypes'] = url_types

uti_declarations = list(info.get('UTExportedTypeDeclarations') or [])
if not any(entry.get('UTTypeIdentifier') == patch_uti for entry in uti_declarations if isinstance(entry, dict)):
    uti_declarations.append({
        'UTTypeConformsTo': ['public.data'],
        'UTTypeDescription': '3105 Patch Package',
        'UTTypeIdentifier': patch_uti,
        'UTTypeTagSpecification': {
            'public.filename-extension': ['3105'],
            'public.mime-type': 'application/x-3105-patch',
        },
    })
info['UTExportedTypeDeclarations'] = uti_declarations
info['LSSupportsOpeningDocumentsInPlace'] = True

with open(path, 'wb') as fh:
    plistlib.dump(info, fh, fmt=plistlib.FMT_XML, sort_keys=False)
PY

plutil -lint "$PLIST" >/dev/null
plutil -extract CFBundleDocumentTypes xml1 -o - "$PLIST" | grep -Fq 'com.yangjiii.3105.patch-package'
plutil -extract CFBundleURLTypes xml1 -o - "$PLIST" | grep -Fq 'threeoneosfive'
plutil -extract UTExportedTypeDeclarations xml1 -o - "$PLIST" | grep -Fq 'application/x-3105-patch'

echo "Merged 3105 1.0 document and URL import metadata into $PLIST"
