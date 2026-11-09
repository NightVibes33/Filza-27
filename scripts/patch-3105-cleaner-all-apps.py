#!/usr/bin/env python3
"""Restore main's exact Cleaner UI and make new exploits backend-only.

Only real accessible cache-positive containers appear in main's app list.
No Airlift metadata placeholders, fake zero-size rows, UI-only safety-stop
rows, extra app category, or changed Cleaner controls.
"""
from pathlib import Path

view_path = Path("ThirdParty/3105/Sources/CleanerView.swift")
catalog_path = Path("ThirdParty/3105/Sources/CleanerCatalog.swift")

ACT_BEFORE = "                    activateContainer: { application in\n                    var activationError: NSString?\n                        return MCMActivateContainerPath(\n                        2,\n                            application.bundleID,\n                        false,\n                        &activationError\n                        )\n                    },"
ACT_AFTER = "                    activateContainer: { application in\n                        // FILZA_MAIN_CLEANER_PARITY: only extend the original\n                        // real root resolver; never add metadata-only rows.\n                        var activationError: NSString?\n                        if let direct = MCMActivateContainerPath(\n                            2, application.bundleID, false, &activationError\n                        ), ContainerStore.isApplicationContainerPath(direct),\n                           (try? LimitedCleanerService.scan(\n                               containerURL: URL(fileURLWithPath: direct, isDirectory: true),\n                               rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }\n                           )) != nil {\n                            return direct\n                        }\n                        guard ContainerStore.isApplicationContainerPath(application.containerPath) else {\n                            return nil\n                        }\n                        return FZWorseQueryGrantDirectory(application.containerPath)\n                    },"
CLEAN_BEFORE = "                guard let containerPath = ContainerStore.resolveAppContainerPath(\n                    bundleID: record.app.bundleID\n                ) else {"
CLEAN_AFTER = "                // Revalidate the exact root that passed the real cache scan.\n                let scannedRoot = record.app.containerPath\n                let stillReadable: String? = ContainerStore.isApplicationContainerPath(scannedRoot)\n                    && (try? LimitedCleanerService.scan(\n                        containerURL: URL(fileURLWithPath: scannedRoot, isDirectory: true),\n                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }\n                    )) != nil ? scannedRoot : nil\n                guard let containerPath = stillReadable ??\n                    ContainerStore.resolveAppContainerPath(bundleID: record.app.bundleID) else {"
CAT_BEFORE = "            guard shouldIncludeBundleID(bundleID),\n                  scannedBundleIDs.insert(bundleID).inserted,\n                  let containerPath = activateContainer(application),\n                  isValidContainerPath(containerPath),\n                  let usage = usageForContainer(containerPath),\n                  usage.totalBytes > 0 else {\n                continue\n            }\n            records.append("
CAT_AFTER = "            guard shouldIncludeBundleID(bundleID),\n                  !scannedBundleIDs.contains(bundleID),\n                  let containerPath = activateContainer(application),\n                  isValidContainerPath(containerPath),\n                  let usage = usageForContainer(containerPath),\n                  usage.totalBytes > 0 else {\n                continue\n            }\n            // Failed discovery does not suppress a later valid cache root.\n            scannedBundleIDs.insert(bundleID)\n            records.append("

def one(source, before, after, label):
    count = source.count(before)
    if count != 1:
        raise SystemExit(f"Cleaner main parity: {label}, expected once, got {count}")
    return source.replace(before, after, 1)

old_view = view_path.read_text(encoding="utf-8")
old_catalog = catalog_path.read_text(encoding="utf-8")
# The pinned main build stages upstream 3105 before our adapter. The staged
# unmodified Cleaner, not an older checked-in snapshot, is the UI baseline.
assert "airliftCatalog" not in old_view, "An earlier patch altered main Cleaner UI"
view = one(one(old_view, ACT_BEFORE, ACT_AFTER, "original MCM route"),
           CLEAN_BEFORE, CLEAN_AFTER, "original clean root")
catalog = one(old_catalog, CAT_BEFORE, CAT_AFTER, "deduplicate verified roots only")
assert view.replace(ACT_AFTER, ACT_BEFORE, 1).replace(
    CLEAN_AFTER, CLEAN_BEFORE, 1) == old_view
assert catalog.replace(CAT_AFTER, CAT_BEFORE, 1) == old_catalog
for name in (
    "allCleanerRecords", "remoteInventories", "remoteMessages",
    "remoteOperationsLocked", "airliftCatalog", "airliftSection",
    "Erosion app containers", "Not inspected • tap to inspect",
    "Recovery required before remote access",
):
    assert name not in view, "Forbidden additional Cleaner UI/rows: " + name
for name in (
    "ForEach(filteredRecords)", "ContainerStore.installedAppsFromAPI()",
    "ContainerStore.installedAppsFromMCM",
    "ContainerStore.installedAppsFromMHACandidates",
    "ContainerStore.launchServicesStoreIdentifiers()",
    "LimitedCleanerService.clean", "FILZA_MAIN_CLEANER_PARITY",
    "FZWorseQueryGrantDirectory(application.containerPath)",
):
    assert name in view, "Missing main feature or backend: " + name
view_path.write_text(view, encoding="utf-8")
catalog_path.write_text(catalog, encoding="utf-8")
print("GREEN: exact main Cleaner UI preserved; MCM + worse_query real-root fallback; safe cache-only cleaning")
