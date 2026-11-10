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
ACT_AFTER = "                    activateContainer: { application in\n                        // FILZA_MAIN_CLEANER_PARITY: preserve existing UI,\n                        // but scan each reachable cache tree only ONCE.\n                        // Checking a container root costs much less than\n                        // recursively measuring its entire cache repeatedly.\n                        func readableContainer(_ value: String) -> Bool {\n                            guard ContainerStore.isApplicationContainerPath(value) else { return false }\n                            return (try? FileManager.default.contentsOfDirectory(atPath: value)) != nil\n                        }\n                        let ownHome = NSHomeDirectory()\n                        if application.bundleID == Bundle.main.bundleIdentifier,\n                           readableContainer(ownHome) { return ownHome }\n                        var activationError: NSString?\n                        if let direct = MCMActivateContainerPath(\n                            2, application.bundleID, false, &activationError\n                        ), readableContainer(direct) { return direct }\n                        let candidate = application.containerPath\n                        guard ContainerStore.isApplicationContainerPath(candidate) else { return nil }\n                        if readableContainer(candidate) { return candidate }\n                        return FZWorseQueryGrantDirectory(candidate)\n                    },"
CLEAN_BEFORE = "                guard let containerPath = ContainerStore.resolveAppContainerPath(\n                    bundleID: record.app.bundleID\n                ) else {"
CLEAN_AFTER = "                // Revalidate the exact root that passed the real cache scan.\n                let scannedRoot = record.app.containerPath\n                let stillReadable: String? = ContainerStore.isApplicationContainerPath(scannedRoot)\n                    && (try? LimitedCleanerService.scan(\n                        containerURL: URL(fileURLWithPath: scannedRoot, isDirectory: true),\n                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }\n                    )) != nil ? scannedRoot : nil\n                guard let containerPath = stillReadable ??\n                    ContainerStore.resolveAppContainerPath(bundleID: record.app.bundleID) else {"
CAT_BEFORE = "            guard shouldIncludeBundleID(bundleID),\n                  scannedBundleIDs.insert(bundleID).inserted,\n                  let containerPath = activateContainer(application),\n                  isValidContainerPath(containerPath),\n                  let usage = usageForContainer(containerPath),\n                  usage.totalBytes > 0 else {\n                continue\n            }\n            records.append("
CAT_AFTER = "            guard shouldIncludeBundleID(bundleID),\n                  !scannedBundleIDs.contains(bundleID),\n                  let containerPath = activateContainer(application),\n                  isValidContainerPath(containerPath),\n                  let usage = usageForContainer(containerPath),\n                  usage.totalBytes > 0 else {\n                continue\n            }\n            // Failed discovery does not suppress a later valid cache root.\n            scannedBundleIDs.insert(bundleID)\n            records.append("
EMPTY_TITLE_BEFORE = "                    Text(language.text(\"cleaner.empty_title\"))"
EMPTY_TITLE_AFTER = "                    Text(\"No Accessible Caches Verified\")"
EMPTY_MESSAGE_BEFORE = "                    Text(language.text(\"cleaner.empty_message\"))"
EMPTY_MESSAGE_AFTER = "                    Text(\"Other installed apps may still contain caches. Filza found no cache folders it could verify as readable with current permissions.\")"
SCAN_BEFORE = "                log(\n                    \"cleaner: scan complete bundles=\\(processedCount) \" +\n                        \"reclaimableApps=\\(discoveredRecords.count)\"\n                )"
SCAN_AFTER = "                log(\n                    \"cleaner: scan complete bundles=\\(processedCount) \" +\n                        \"reclaimableApps=\\(discoveredRecords.count)\"\n                )\n                FilzaDiagnosticsAppend(\n                    \"Cleaner\",\n                    \"Catalog counts: API=\\(apiApps.count), MCM identifiers=\\(dynamicIdentifiers.count), \" +\n                    \"LaunchServices=\\(launchServicesIdentifiers.count), resolved MHA=\\(mhaApps.count), \" +\n                    \"verified cache-positive=\\(discoveredRecords.count). \" +\n                    \"No result does not mean no caches exist.\"\n                )"

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
view = one(view, EMPTY_TITLE_BEFORE, EMPTY_TITLE_AFTER, "truthful empty title")
view = one(view, EMPTY_MESSAGE_BEFORE, EMPTY_MESSAGE_AFTER, "truthful empty message")
view = one(view, SCAN_BEFORE, SCAN_AFTER, "discovery-vs-access diagnostics")
catalog = one(old_catalog, CAT_BEFORE, CAT_AFTER, "deduplicate verified roots only")
assert view.replace(ACT_AFTER, ACT_BEFORE, 1).replace(
    CLEAN_AFTER, CLEAN_BEFORE, 1).replace(
    EMPTY_TITLE_AFTER, EMPTY_TITLE_BEFORE, 1).replace(
    EMPTY_MESSAGE_AFTER, EMPTY_MESSAGE_BEFORE, 1).replace(
    SCAN_AFTER, SCAN_BEFORE, 1) == old_view
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
    "FZWorseQueryGrantDirectory(candidate)",
    "No Accessible Caches Verified",
):
    assert name in view, "Missing main feature or backend: " + name
view_path.write_text(view, encoding="utf-8")
catalog_path.write_text(catalog, encoding="utf-8")
print("GREEN: exact main Cleaner UI preserved; MCM + worse_query real-root fallback; safe cache-only cleaning")
