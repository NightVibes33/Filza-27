#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105/Sources"
BROWSER="$ROOT/AppDataBrowserView.swift"
ZIP="$ROOT/ZIPArchiveWriter.swift"

for path in "$BROWSER" "$ZIP" "$ROOT/FilzaAppIPAExporter.swift"; do
  test -f "$path" || { echo "Missing 3105 IPA export source: $path" >&2; exit 1; }
done

python3 - "$BROWSER" "$ZIP" <<'PY'
from pathlib import Path
import sys

browser_path = Path(sys.argv[1])
zip_path = Path(sys.argv[2])

browser = browser_path.read_text(encoding="utf-8")

state_anchor = '''    @State private var hasLoaded = false
'''
state_replacement = '''    @State private var hasLoaded = false
    @State private var exportingBundleID: String?
    @State private var ipaExportItem: FilzaIPAExportItem?
    @State private var ipaExportError: String?
    @State private var preparedIPAs: [String: URL] = [:]
    @State private var preparedEncryption: [String: String] = [:]
    @State private var decryptedIPAs: [String: URL] = [:]
    @State private var pairedPrepareCandidate: InstalledApp?
'''
if state_anchor not in browser:
    raise SystemExit("3105 IPA export patch: state anchor changed")
browser = browser.replace(state_anchor, state_replacement, 1)

# 3105 1.0.1 added workspace initialization and navigationDestination after
# onAppear. Anchor on navigationDestination itself instead of assuming an exact
# onAppear body or an immediate NavigationStack closing brace. This keeps the
# export presentation attached to the same appList modifier chain and survives
# upstream additions to onAppear.
navigation_anchor = '''            .navigationDestination(for: FileBrowserDestination.self) { destination in
'''
navigation_replacement = '''            .sheet(item: $ipaExportItem) { item in
                FilzaIPAExportDocumentPicker(item: item) {
                    ipaExportItem = nil
                }
            }
            .alert(
                "App Preparation",
                isPresented: Binding(
                    get: { ipaExportError != nil },
                    set: { if !$0 { ipaExportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { ipaExportError = nil }
            } message: {
                Text(ipaExportError ?? "Unknown IPA export error")
            }
            .confirmationDialog(
                "Prepare with paired Airlift?",
                isPresented: Binding(
                    get: { pairedPrepareCandidate != nil },
                    set: { if !$0 { pairedPrepareCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let request = pairedPrepareCandidate {
                    Button("Attempt paired preparation") {
                        pairedPrepareCandidate = nil
                        prepareIPAViaAirlift(request)
                    }
                }
                Button("Cancel", role: .cancel) { pairedPrepareCandidate = nil }
            } message: {
                Text("Paired folder exports can temporarily relocate a remote object. " +
                     "Do not proceed with an unresolved restoration incident. " +
                     "This is never an automatic fallback from normal Prepare.")
            }
            .navigationDestination(for: FileBrowserDestination.self) { destination in
'''
if navigation_anchor not in browser:
    raise SystemExit("3105 IPA export patch: navigation destination anchor changed")
browser = browser.replace(navigation_anchor, navigation_replacement, 1)

version_anchor = '''            if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
    }
'''
version_replacement = '''            if exportingBundleID == app.bundleID {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing IPA")
            } else if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        .contextMenu {
            if let ipa = preparedIPAs[app.bundleID] {
                if let verified = decryptedIPAs[app.bundleID] {
                    Button {
                        ipaExportItem = FilzaIPAExportItem(url: verified)
                    } label: {
                        Label("Export decrypted IPA", systemImage: "checkmark.shield")
                    }
                }
                Button {
                    decryptPreparedIPA(app)
                } label: {
                    Label("Decrypt", systemImage: "lock.open")
                }
                .disabled(exportingBundleID != nil)
                Button {
                    ipaExportItem = FilzaIPAExportItem(url: ipa)
                } label: {
                    Label("Export prepared IPA", systemImage: "square.and.arrow.up")
                }
                Button {
                    prepareIPA(app)
                } label: {
                    Label("Prepare again", systemImage: "arrow.clockwise")
                }
                .disabled(exportingBundleID != nil)
            } else {
                Button {
                    prepareIPA(app)
                } label: {
                    Label("Prepare", systemImage: "shippingbox")
                }
                .disabled(exportingBundleID != nil)
                if airliftCatalog.apps.contains(where: {
                    $0.bundleID == app.bundleID && $0.bundlePath != nil
                }) {
                    Button {
                        pairedPrepareCandidate = app
                    } label: {
                        Label("Prepare with paired Airlift", systemImage: "network")
                    }
                    .disabled(exportingBundleID != nil || FilzaAirlift.restorationStopped)
                }
            }
        }
    }
'''
if version_anchor not in browser:
    raise SystemExit("3105 IPA export patch: app row anchor changed")
browser = browser.replace(version_anchor, version_replacement, 1)

reload_anchor = '''    private func reload() {
'''
export_method = '''    // Ordinary Prepare NEVER performs a paired folder move as a fallback.
    // A SideStore-signed app may see another bundle's metadata but lack its
    // filesystem permissions. Preserve that error and offer an explicit
    // alternative only when no unresolved restore incident is present.
    private func prepareIPA(_ app: InstalledApp) {
        guard exportingBundleID == nil else { return }
        let bundleID = app.bundleID
        let displayName = app.displayName
        let version = app.version
        exportingBundleID = bundleID
        ipaExportError = nil
        preparedIPAs[bundleID] = nil
        preparedEncryption[bundleID] = nil
        decryptedIPAs[bundleID] = nil
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try FilzaAppIPAExporter.repackage(
                        bundleID: bundleID, displayName: displayName, version: version
                    )
                }.value
                let status = try await Task.detached(priority: .utility) {
                    try FilzaAirliftIPAExporter.inspectIPA(url)
                }.value
                preparedIPAs[bundleID] = url
                preparedEncryption[bundleID] = status
                ipaExportError = "Prepared \(displayName).\n\(status)\nLong-press again for Decrypt or Export prepared IPA."
            } catch {
                FilzaDiagnosticsAppend(
                    "IPA", "Local Prepare \(bundleID) failed: \(error.localizedDescription)"
                )
                ipaExportError = "Local Prepare unavailable for \(displayName): " +
                    error.localizedDescription +
                    "\nThis does not mean the app is absent. SideStore signing does not grant " +
                    "access to other apps' private bundles. No paired remote read was attempted."
            }
            exportingBundleID = nil
        }
    }

    // Explicit, separately confirmed operation: may move remote app objects.
    // Never bypass an unresolved original-directory restoration incident.
    private func prepareIPAViaAirlift(_ app: InstalledApp) {
        guard exportingBundleID == nil else { return }
        guard !FilzaAirlift.restorationStopped else {
            ipaExportError = "SAFETY STOP: remote restoration is not verified. " +
                "Do not retry app-bundle reads or writes until recovery is resolved."
            return
        }
        guard let paired = airliftCatalog.apps.first(where: {
            $0.bundleID == app.bundleID && $0.bundlePath != nil
        }) else {
            ipaExportError = "No paired app-bundle path was discovered for \(app.displayName)."
            return
        }
        let bundleID = app.bundleID
        let displayName = app.displayName
        exportingBundleID = bundleID
        ipaExportError = nil
        preparedIPAs[bundleID] = nil
        preparedEncryption[bundleID] = nil
        decryptedIPAs[bundleID] = nil
        Task {
            do {
                let export = try await FilzaAirliftIPAExporter.export(paired)
                let status = try await Task.detached(priority: .utility) {
                    try FilzaAirliftIPAExporter.inspectIPA(export.fileURL)
                }.value
                preparedIPAs[bundleID] = export.fileURL
                preparedEncryption[bundleID] = status
                ipaExportError = "Prepared \(displayName) using paired access.\n\(status)" +
                    "\nLong-press to export or attempt decryption."
            } catch {
                FilzaDiagnosticsAppend(
                    "IPA", "Paired Prepare \(bundleID) failed: \(error.localizedDescription)"
                )
                ipaExportError = "Paired preparation failed for \(displayName): " +
                    error.localizedDescription
            }
            exportingBundleID = nil
        }
    }

    // In-process FairPlay research backend: no second helper IPA.
    // Airlift copies a staged bundle but cannot authorize the kernel to
    // decrypt an original installed binary on unsupported iOS builds.
    private func decryptPreparedIPA(_ app: InstalledApp) {
        guard let prepared = preparedIPAs[app.bundleID],
              exportingBundleID == nil else {
            ipaExportError = "Prepare this app first."
            return
        }
        if let existing = decryptedIPAs[app.bundleID] {
            ipaExportItem = FilzaIPAExportItem(url: existing)
            return
        }
        let id = app.bundleID
        let pairedBundlePath = airliftCatalog.apps.first { $0.bundleID == id }?.bundlePath
        exportingBundleID = id
        ipaExportError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FilzaFairPlayBackend.decryptPreparedIPA(
                        bundleID: id, preparedIPA: prepared,
                        pairedBundlePath: pairedBundlePath
                    )
                }.value
                if result == prepared {
                    ipaExportError = "The prepared IPA already contains unencrypted arm64 binaries. Use Export prepared IPA."
                } else {
                    decryptedIPAs[id] = result
                    ipaExportError = "Decrypted IPA verified. Long-press again to Export decrypted IPA."
                }
            } catch {
                ipaExportError = "Decrypt failed: \(error.localizedDescription)"
            }
            exportingBundleID = nil
        }
    }

    private func reload() {
'''
if reload_anchor not in browser:
    raise SystemExit("3105 IPA export patch: reload anchor changed")
browser = browser.replace(reload_anchor, export_method, 1)
browser_path.write_text(browser, encoding="utf-8")

zip_text = zip_path.read_text(encoding="utf-8")

entry_anchor = '''        let modifiedDate: UInt16
        let localHeaderOffset: UInt32
'''
entry_replacement = '''        let modifiedDate: UInt16
        let localHeaderOffset: UInt32
        let unixMode: UInt32
'''
if entry_anchor not in zip_text:
    raise SystemExit("3105 IPA export patch: ZIP entry anchor changed")
zip_text = zip_text.replace(entry_anchor, entry_replacement, 1)

append_entry_anchor = '''            modifiedTime: date.time,
            modifiedDate: date.date,
            localHeaderOffset: UInt32(offset)
        )
'''
append_entry_replacement = '''            modifiedTime: date.time,
            modifiedDate: date.date,
            localHeaderOffset: UInt32(offset),
            unixMode: unixMode(for: sourceURL, isDirectory: isDirectory)
        )
'''
if append_entry_anchor not in zip_text:
    raise SystemExit("3105 IPA export patch: ZIP entry initializer changed")
zip_text = zip_text.replace(append_entry_anchor, append_entry_replacement, 1)

permissions_anchor = '''        let permissions: UInt32 = entry.isDirectory ? 0o040755 : 0o100600
        header.appendLittleEndian((permissions << 16) | (entry.isDirectory ? 0x10 : 0))
'''
permissions_replacement = '''        header.appendLittleEndian((entry.unixMode << 16) | (entry.isDirectory ? 0x10 : 0))
'''
if permissions_anchor not in zip_text:
    raise SystemExit("3105 IPA export patch: ZIP permissions anchor changed")
zip_text = zip_text.replace(permissions_anchor, permissions_replacement, 1)

append_tree_anchor = '''    private static func appendTree(
'''
ipa_method = '''    static func writeIPA(
        appBundleURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> ZIPArchiveWriteResult {
        guard appBundleURL.pathExtension.lowercased() == "app" else {
            throw ZIPArchiveWriterError.invalidSource
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ZIPArchiveWriterError.writeFailed
        }

        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-ipa-\\(UUID().uuidString)")
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw ZIPArchiveWriterError.writeFailed
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        do {
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }
            var entries: [Entry] = []
            var seenPaths = Set<String>()
            var sourceBytes: Int64 = 0

            try appendTree(
                rootedAt: appBundleURL.standardizedFileURL,
                archiveRootName: "Payload/\\(appBundleURL.lastPathComponent)",
                handle: handle,
                entries: &entries,
                seenPaths: &seenPaths,
                sourceBytes: &sourceBytes,
                fileManager: fileManager
            )

            guard entries.count <= Int(UInt16.max) else {
                throw ZIPArchiveWriterError.archiveTooLarge
            }
            let centralOffset = try currentOffset(handle)
            for entry in entries {
                try writeCentralHeader(entry, to: handle)
            }
            let endOffset = try currentOffset(handle)
            let centralSize = endOffset - centralOffset
            guard centralOffset <= UInt64(UInt32.max), centralSize <= UInt64(UInt32.max) else {
                throw ZIPArchiveWriterError.archiveTooLarge
            }
            try writeEndRecord(
                entryCount: UInt16(entries.count),
                centralSize: UInt32(centralSize),
                centralOffset: UInt32(centralOffset),
                to: handle
            )
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return ZIPArchiveWriteResult(entryCount: entries.count, sourceBytes: sourceBytes)
        } catch let error as ZIPArchiveWriterError {
            throw error
        } catch {
            throw ZIPArchiveWriterError.writeFailed
        }
    }

    private static func appendTree(
'''
if append_tree_anchor not in zip_text:
    raise SystemExit("3105 IPA export patch: appendTree anchor changed")
zip_text = zip_text.replace(append_tree_anchor, ipa_method, 1)

resource_keys_anchor = '''    private static var resourceKeys: [URLResourceKey] {
'''
unix_mode_method = '''    private static func unixMode(for url: URL, isDirectory: Bool) -> UInt32 {
        let typeBits: UInt32 = isDirectory ? 0o040000 : 0o100000
        let fallback: UInt32 = isDirectory ? 0o755 : 0o644
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let raw = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? fallback
        return typeBits | (raw & 0o7777)
    }

    private static var resourceKeys: [URLResourceKey] {
'''
if resource_keys_anchor not in zip_text:
    raise SystemExit("3105 IPA export patch: resource keys anchor changed")
zip_text = zip_text.replace(resource_keys_anchor, unix_mode_method, 1)

zip_path.write_text(zip_text, encoding="utf-8")
PY

grep -Fq 'Label("Prepare", systemImage:' "$BROWSER"
grep -Fq 'Label("Decrypt", systemImage:' "$BROWSER"
grep -Fq 'preparedIPAs[app.bundleID]' "$BROWSER"
grep -Fq 'decryptPreparedIPA(app)' "$BROWSER"
grep -Fq 'FilzaFairPlayBackend.decryptPreparedIPA' "$BROWSER"
grep -Fq 'Label("Export decrypted IPA"' "$BROWSER"
grep -Fq 'FilzaAppIPAExporter.repackage' "$BROWSER"
grep -Fq 'FilzaIPAExportDocumentPicker' "$BROWSER"
grep -Fq '.navigationDestination(for: FileBrowserDestination.self)' "$BROWSER"
grep -Fq 'static func writeIPA(' "$ZIP"
grep -Fq 'archiveRootName: "Payload/' "$ZIP"
grep -Fq 'unixMode: unixMode(for:' "$ZIP"

echo "Patched 3105 Apps Manager with long-press IPA repackaging and Payload/*.app ZIP layout"
