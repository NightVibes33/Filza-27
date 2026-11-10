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
    @State private var preparedDirectories: [String: URL] = [:]
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
            .onAppear {
                // Erosion's prepared .app directories persist across launches.
                preparedDirectories = FilzaAirliftIPAExporter.preparedDirectories()
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
                Text(ipaExportError ?? "Unknown IPA error")
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
            } else if preparedDirectories[app.bundleID] != nil {
                Text("Prepared")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            } else if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // A discoverable menu in every 3105 app row, in addition to
            // the original long-press context menu. No extra Erosion tab.
            Menu {
                Button {
                    prepareIPA(app)
                } label: {
                    Label("Prepare with Airlift", systemImage: "arrow.down.doc")
                }
                .disabled(exportingBundleID != nil || FilzaAirlift.restorationStopped)
                Button {
                    decryptPreparedIPA(app)
                } label: {
                    Label("Package prepared IPA", systemImage: "doc.zipper")
                }
                .disabled(preparedDirectories[app.bundleID] == nil || exportingBundleID != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Airlift IPA actions for \(app.displayName)")
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        .contextMenu {
            // Erosion's ORIGINAL two-item context menu, without another tab.
            Button {
                prepareIPA(app)
            } label: {
                Label("Prepare", systemImage: "arrow.down.doc")
            }
            .disabled(exportingBundleID != nil)
            Button {
                decryptPreparedIPA(app)
            } label: {
                Label("Decrypt", systemImage: "doc.zipper")
            }
            .disabled(preparedDirectories[app.bundleID] == nil || exportingBundleID != nil)
        }
    }
'''
if version_anchor not in browser:
    raise SystemExit("3105 IPA export patch: app row anchor changed")
browser = browser.replace(version_anchor, version_replacement, 1)

reload_anchor = '''    private func reload() {
'''
export_method = r'''    // ER0SION_PREPARE_PARITY: InstallationProxy app bundle path only.
    // Prepare uses Airlift's original al_exploit_read_folder path. The
    // resulting ZIP contains the .app CONTENTS and becomes a persistent
    // prepared .app folder, just as Erosion AppsManagement does.
    private func prepareIPA(_ app: InstalledApp) {
        guard exportingBundleID == nil else { return }
        guard !FilzaAirlift.restorationStopped else {
            ipaExportError = "Airlift folder restoration has not been verified. " +
                "IPA Prepare cannot issue another remote read."
            return
        }
        let id = app.bundleID
        exportingBundleID = id
        ipaExportError = nil
        Task {
            do {
                // Don't rely on a possibly empty earlier pairing/catalog scan.
                let discovered = try await FilzaAirlift.discover()
                guard let remote = discovered.apps.first(where: {
                    $0.bundleID == id && $0.bundlePath != nil
                }) else {
                    ipaExportError = "InstallationProxy did not return an app-bundle path for \(app.displayName)."
                    exportingBundleID = nil
                    return
                }
                let prepared = try await FilzaAirliftIPAExporter.prepare(remote)
                preparedDirectories[id] = prepared
                preparedIPAs[id] = nil
                decryptedIPAs[id] = nil
                preparedEncryption[id] = nil
                FilzaDiagnosticsAppend("IPA", "Erosion Prepare saved .app: \(id)")
                ipaExportError = "Prepared \(app.displayName). Long-press again for Decrypt (IPA packaging)."
            } catch {
                FilzaDiagnosticsAppend("IPA", "Erosion Prepare \(id) failed: \(error.localizedDescription)")
                ipaExportError = "Prepare failed for \(app.displayName): \(error.localizedDescription)"
            }
            exportingBundleID = nil
        }
    }

    // Erosion's "Decrypt" packages Payload/<name>.app. Packaging does NOT
    // decrypt FairPlay-encrypted code and must never be reported as such.
    private func decryptPreparedIPA(_ app: InstalledApp) {
        guard let prepared = preparedDirectories[app.bundleID],
              exportingBundleID == nil else {
            ipaExportError = "Prepare this app with Airlift first."
            return
        }
        exportingBundleID = app.bundleID
        ipaExportError = nil
        let id = app.bundleID
        let name = app.displayName
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try FilzaAirliftIPAExporter.makeIPA(
                        from: prepared, displayName: name, bundleID: id
                    )
                }.value
                preparedIPAs[id] = result.fileURL
                preparedEncryption[id] = result.encryptionStatus
                FilzaDiagnosticsAppend("IPA", "Erosion-style IPA packaged \(id); \(result.encryptionStatus)")
                ipaExportItem = FilzaIPAExportItem(url: result.fileURL)
            } catch {
                ipaExportError = "IPA packaging failed: \(error.localizedDescription)"
            }
            exportingBundleID = nil
        }
    }

    // No FairPlay/extra app action is inserted into Erosion's IPA menu.

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

# Erosion parity: the app menu exposes its original two operations.
grep -Fq 'Label("Prepare", systemImage: "arrow.down.doc")' "$BROWSER"
grep -Fq 'Label("Decrypt", systemImage: "doc.zipper")' "$BROWSER"
grep -Fq 'preparedDirectories[app.bundleID]' "$BROWSER"
grep -Fq 'FilzaAirlift.discover()' "$BROWSER"
grep -Fq 'FilzaAirliftIPAExporter.prepare(remote)' "$BROWSER"
grep -Fq 'FilzaAirliftIPAExporter.makeIPA(' "$BROWSER"
! grep -Fq 'FilzaFairPlayBackend.decryptPreparedIPA' "$BROWSER"
! grep -Fq 'FilzaAppIPAExporter.repackage' "$BROWSER"
grep -Fq 'FilzaIPAExportDocumentPicker' "$BROWSER"
grep -Fq '.navigationDestination(for: FileBrowserDestination.self)' "$BROWSER"
grep -Fq 'static func writeIPA(' "$ZIP"
grep -Fq 'archiveRootName: "Payload/' "$ZIP"
grep -Fq 'unixMode: unixMode(for:' "$ZIP"

echo "Patched 3105 Apps Manager with long-press IPA repackaging and Payload/*.app ZIP layout"
