#!/usr/bin/env bash
set -euo pipefail

PAIRING="ThirdParty/3105/Sources/FilzaSharedPairingSupport.swift"

test -f "$PAIRING" || {
  echo "Missing 3105 shared pairing source: $PAIRING" >&2
  exit 1
}

python3 - "$PAIRING" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_presenter = '''        .sheet(isPresented: $showingPairingImporter) {
            // Use the exact same document picker and broad pairing-file type set
            // as ByeTunes. SwiftUI's fileImporter was graying out valid pairing
            // files that ByeTunes' UIDocumentPicker accepts on-device.
            DocumentPicker(types: [.data, .xml, .propertyList, .item]) { url in
                handlePairingImport(url: url)
            }
        }
'''
new_presenter = '''        .fileImporter(
            isPresented: $showingPairingImporter,
            // `.item` deliberately accepts the same broad class of files that
            // ByeTunes' UIDocumentPicker accepts while letting SwiftUI own the
            // system Files presentation. This avoids stacking a second SwiftUI
            // sheet above 3105 Settings inside Filza's outer page sheet.
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handlePairingImport(result)
        }
'''
if old_presenter not in text:
    raise SystemExit("3105 pairing importer presenter anchor changed")
text = text.replace(old_presenter, new_presenter, 1)

old_handler = '''    private func handlePairingImport(url: URL?) {
        guard let url else { return }

        do {
            manager.stopHeartbeat()
            try manager.importPairingFile(from: url)
            FilzaSharedPairingSupport.resetAfterPairingChange()
            manager.startHeartbeat(forceReconnect: true) { success in
                Task { @MainActor in
                    message = success
                        ? "Pairing saved for Filza 27 and connected. ByeTunes and 3105 now share this device connection."
                        : "Pairing was saved, but the device tunnel is not connected yet. Enable LocalDevVPN and tap Reconnect."
                    showingMessage = true
                }
            }
        } catch {
            manager.refreshExpectedPairingFileState()
            message = error.localizedDescription
            showingMessage = true
        }
    }
'''
new_handler = '''    private func handlePairingImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
            showingMessage = true

        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                manager.stopHeartbeat()
                try manager.importPairingFile(from: url)
                FilzaSharedPairingSupport.resetAfterPairingChange()
                manager.startHeartbeat(forceReconnect: true) { success in
                    Task { @MainActor in
                        message = success
                            ? "Pairing saved for Filza 27 and connected. ByeTunes and 3105 now share this device connection."
                            : "Pairing was saved, but the device tunnel is not connected yet. Enable LocalDevVPN and tap Reconnect."
                        showingMessage = true
                    }
                }
            } catch {
                manager.refreshExpectedPairingFileState()
                message = error.localizedDescription
                showingMessage = true
            }
        }
    }
'''
if old_handler not in text:
    raise SystemExit("3105 pairing importer handler anchor changed")
text = text.replace(old_handler, new_handler, 1)

if '.sheet(isPresented: $showingPairingImporter)' in text:
    raise SystemExit("3105 pairing importer still uses nested SwiftUI sheet")
if 'allowedContentTypes: [.item]' not in text:
    raise SystemExit("3105 pairing importer is not broad-file selectable")
if 'handlePairingImport(_ result: Result<[URL], Error>)' not in text:
    raise SystemExit("3105 pairing importer result handler missing")

path.write_text(text, encoding="utf-8")
PY

echo "Patched 3105 pairing import to use broad SwiftUI fileImporter without nested modal dismissal"
