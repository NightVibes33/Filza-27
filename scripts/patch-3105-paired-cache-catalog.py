#!/usr/bin/env python3
"""Feed 3105's original Cleaner real paired app-data candidates.

The InstallationProxy catalog is metadata, not access. Every candidate still
passes through the existing verified local filesystem scanner and worse_query
sandbox-extension gate. No extra Cleaner UI, fake rows or remote deletion.
"""
from pathlib import Path

p = Path("ThirdParty/3105/Sources/CleanerView.swift")
view = p.read_text(encoding="utf-8")
assert "FILZA_MAIN_CLEANER_PARITY" in view, "Apply main Cleaner parity first"

def once(before: str, after: str, label: str):
    global view
    n = view.count(before)
    if n != 1:
        raise SystemExit(f"Cleaner paired catalog: {label} expected once, got {n}")
    view = view.replace(before, after, 1)

once(
    "    @State private var records: [CleanerAppRecord] = []",
    """    // Real InstallationProxy bundle-to-container identities used by the
    // existing local cache scanner. They do not grant read/write privileges.
    @ObservedObject private var pairedInventory = FilzaAirliftCatalogStore.shared
    @State private var needsPairedRescan = false
    @State private var awaitingPairedInventory = false
    @State private var records: [CleanerAppRecord] = []""",
    "state")

once(
    """            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reload()
            }""",
    """            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                // InstallationProxy discovery is metadata-only. Nothing in
                // this step remotely modifies or reads an app folder.
                if pairedInventory.apps.isEmpty && FilzaAirlift.pairedRecord() != nil {
                    // Do not scan 341 containers twice. Wait briefly for
                    // InstallationProxy's metadata-only catalog first.
                    awaitingPairedInventory = true
                    pairedInventory.refresh()
                } else {
                    reload()
                }
            }""",
    "metadata-only catalog start")

once(
    """            .onReceive(NotificationCenter.default.publisher(""",
    """            .onReceive(pairedInventory.$apps) { apps in
                guard hasLoaded, !apps.isEmpty else { return }
                if awaitingPairedInventory {
                    awaitingPairedInventory = false
                    reload()
                } else if isScanning {
                    // Refresh once only if new metadata actually arrives.
                    needsPairedRescan = true
                } else if !isCleaning && records.isEmpty {
                    reload()
                }
            }
            .onReceive(pairedInventory.$scanning) { active in
                guard hasLoaded, awaitingPairedInventory, !active else { return }
                // Failed pairing/empty catalog: use the original local scan.
                awaitingPairedInventory = false
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(""",
    "refresh when paired catalog arrives")

# A full inode pass may finish minutes after an otherwise successful Cleaner
# scan. Do not automatically rescan 341 healthy apps for a directory-list
# notification; empty results can retry and Refresh remains available.
once(
    "                if !isBusy { reload() }",
    "                if !isBusy && records.isEmpty { reload() }",
    "skip pointless post-inode rescan")

once(
    """        let requestID = UUID()
        scanID = requestID""",
    """        let pairedApps: [InstalledApp] = pairedInventory.apps.compactMap { remote in
            guard let path = remote.dataPath,
                  ContainerStore.isApplicationContainerPath(path) else { return nil }
            // A valid InstallationProxy identity is useful metadata, not a
            // fake Cleaner row. scanNewApps only adds cache-positive roots.
            return InstalledApp(
                bundleID: remote.bundleID, name: remote.name,
                containerPath: path, version: "", icon: nil
            )
        }
        let requestID = UUID()
        scanID = requestID""",
    "paired snapshot")

once(
    r"""            scanNewApps(apiApps + mcmApps)

            let launchServicesIdentifiers =""",
    """            scanNewApps(apiApps + mcmApps)
            scanNewApps(pairedApps)
            FilzaDiagnosticsAppend(
                "Cleaner",
                "Paired InstallationProxy candidates=\(pairedApps.count); only verified readable cache-positive apps become rows"
            )

            let launchServicesIdentifiers =""",
    "source merge")

once(
    """                isScanning = false
                log(
                    "cleaner: scan complete bundles=""",
    """                isScanning = false
                if needsPairedRescan {
                    needsPairedRescan = false
                    // Defer one rescan only for a newly arrived paired list.
                    DispatchQueue.main.async { reload() }
                }
                log(
                    "cleaner: scan complete bundles=""",
    "late catalog refresh")

once(
    """                let stillReadable: String? = ContainerStore.isApplicationContainerPath(scannedRoot)
                    && (try? LimitedCleanerService.scan(
                        containerURL: URL(fileURLWithPath: scannedRoot, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                    )) != nil ? scannedRoot : nil""",
    """                let accessRoot: String? = ContainerStore.isApplicationContainerPath(scannedRoot)
                    ? (FZWorseQueryPathHasActiveGrant(scannedRoot)
                       ? scannedRoot : FZWorseQueryGrantDirectory(scannedRoot))
                    : nil
                // Tokens may be evicted during the large catalog scan. Renew
                // only a selected app's exact grant, then recheck its cache.
                let stillReadable: String? = accessRoot.flatMap { root in
                    (try? LimitedCleanerService.scan(
                        containerURL: URL(fileURLWithPath: root, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                    )) != nil ? root : nil
                }""",
    "renew selected app grants safely")

assert "pairedInventory.$apps" in view
assert "awaitingPairedInventory" in view
assert "pairedInventory.$scanning" in view
assert "scanNewApps(pairedApps)" in view
assert "FZWorseQueryGrantDirectory(scannedRoot)" in view
for token in ("airliftSection", "allCleanerRecords", "Not inspected •"):
    assert token not in view
p.write_text(view, encoding="utf-8")
print("GREEN: main Cleaner retains original UI and scans verified cache-positive paired app containers")
