#!/usr/bin/env python3
"""Make 3105 Cleaner operate on all discovered installed apps.

Preserve 3105's safe local per-app Caches/tmp cleaning. Add an opt-in paired
Airlift fallback for individually selected apps when direct MCM access fails.
No fake sizes, cross-app grants or blanket delete of remote parent containers.
"""
from pathlib import Path

def replace_one(path: str, before: str, after: str):
    f = Path(path)
    s = f.read_text(encoding="utf-8")
    if after in s:
        return
    count = s.count(before)
    if count != 1:
        raise SystemExit(f"Cleaner source anchor changed ({count}) in {path}: {before[:95]!r}")
    f.write_text(s.replace(before, after, 1), encoding="utf-8")

catalog = "ThirdParty/3105/Sources/CleanerCatalog.swift"
replace_one(catalog,
    "                  scannedBundleIDs.insert(bundleID).inserted,\n",
    "                   !scannedBundleIDs.contains(bundleID),\n")
replace_one(catalog,
    """                  usage.totalBytes > 0 else {
                continue
            }
            records.append(""",
    """                  usage.totalBytes > 0 else {
                continue
            }
            // Only mark an app after an actual accessible cache was found.
            // A failed MCM resolution must not suppress later discoveries.
            scannedBundleIDs.insert(bundleID)
            records.append(""")

cleaner = "ThirdParty/3105/Sources/CleanerView.swift"
replace_one(cleaner,
    """    @ObservedObject private var airliftCatalog = FilzaAirliftCatalogStore.shared""",
    """    @ObservedObject private var airliftCatalog = FilzaAirliftCatalogStore.shared
    // FILZA_ALL_APP_AIRLIFT_CLEANER
    @State private var remoteInventories: [String: FilzaRemoteCleanerInventory] = [:]
    @State private var remoteMessages: [String: String] = [:]
    @State private var remoteBusyBundle: String?
    @State private var remoteConfirmation: String?
    @State private var localScanSummary = "Not scanned yet."
    @State private var lastLocalCleanup = ""
    """)

replace_one(cleaner,
    """            .alert(item: $activeAlert, content: alert(for:))""",
    """            .alert(item: $activeAlert, content: alert(for:))
            .confirmationDialog(
                "Remove verified cache entries?",
                isPresented: Binding(
                    get: { remoteConfirmation != nil },
                    set: { if !$0 { remoteConfirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let bundleID = remoteConfirmation {
                    Button("Clean selected app using Airlift", role: .destructive) {
                        remoteConfirmation = nil
                        cleanRemoteApp(bundleID)
                    }
                }
                Button("Cancel", role: .cancel) { remoteConfirmation = nil }
            } message: {
                Text("Only items confirmed in a complete Airlift cache snapshot " +
                     "from Library/Caches and tmp will be removed. The source app " +
                     "should be closed. Remote deletion cannot be undone; transport " +
                     "success is not proof of reclaimed bytes.")
            }""")

# Erosion's old decorational metadata section is replaced with a real remote
# cache scanner. The paired apps list is independent of local eligible records.
f = Path(cleaner)
s = f.read_text(encoding="utf-8")
start_marker = "    // Erosion does not provide a safe system-wide cache-deletion API."
end_marker = "    private var summarySection: some View {"
if start_marker not in s or end_marker not in s:
    raise SystemExit("Cleaner Erosion section boundary changed")
start = s.index(start_marker)
end = s.index(end_marker, start)
section = r'''    private var airliftSection: some View {
        Section {
            Text(localScanSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !lastLocalCleanup.isEmpty {
                Text(lastLocalCleanup)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(airliftCatalog.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if FilzaAirlift.pairedRecord() == nil {
                Text("Set up Device Pairing in Filza Settings to inspect other " +
                     "applications using Erosion/Airlift.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if airliftCatalog.scanning { ProgressView() }
            ForEach(airliftCatalog.apps) { app in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline.weight(.medium))
                            Text(app.bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if remoteBusyBundle == app.bundleID {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let inventory = remoteInventories[app.bundleID] {
                        Text("\(inventory.entries.count) inspected disposable items; " +
                             ByteCountFormatter.string(
                                 fromByteCount: inventory.bytes, countStyle: .file
                             ) + " estimated cache")
                            .font(.caption)
                        if inventory.canClean {
                            Button(role: .destructive) {
                                remoteConfirmation = app.bundleID
                            } label: {
                                Label("Clean verified Airlift cache", systemImage: "trash")
                            }
                            .disabled(remoteBusyBundle != nil || isBusy)
                        }
                    }
                    if let message = remoteMessages[app.bundleID] {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        scanRemoteApp(app)
                    } label: {
                        Label("Inspect app cache via Airlift", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.dataPath == nil ||
                              remoteBusyBundle != nil || isBusy ||
                              FilzaAirlift.pairedRecord() == nil)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("All installed apps • Erosion/Airlift")
        } footer: {
            Text("The local Cleaner scans accessible caches for every app. " +
                 "Airlift can inspect additional installed apps only when " +
                 "paired transport and safe snapshot restoration succeed. " +
                 "Protected app data is never assumed writable from metadata.")
        }
    }

    private func scanRemoteApp(_ app: FilzaAirliftApp) {
        guard remoteBusyBundle == nil else { return }
        remoteBusyBundle = app.bundleID
        remoteInventories.removeValue(forKey: app.bundleID)
        remoteMessages[app.bundleID] = "Inspecting remote caches…"
        Task {
            do {
                let inventory = try await FilzaAirliftCleaner.inspect(app)
                remoteInventories[app.bundleID] = inventory
                if !inventory.failures.isEmpty {
                    remoteMessages[app.bundleID] = inventory.failures.joined(separator: "; ")
                } else {
                    remoteMessages[app.bundleID] = inventory.entries.isEmpty
                        ? "No removable cache entries were confirmed."
                        : "Snapshot and original-object restoration confirmed. " +
                          "Review estimated size, then choose Clean."
                }
            } catch {
                remoteMessages[app.bundleID] = error.localizedDescription
                FilzaDiagnosticsAppend(
                    "Cleaner", "Airlift scan \(app.bundleID) failed: \(error.localizedDescription)"
                )
            }
            remoteBusyBundle = nil
        }
    }

    private func cleanRemoteApp(_ bundleID: String) {
        guard remoteBusyBundle == nil,
              let inventory = remoteInventories[bundleID],
              inventory.canClean else { return }
        remoteBusyBundle = bundleID
        remoteMessages[bundleID] = "Cleaning inspected cache entries…"
        Task {
            do {
                let result = try await FilzaAirliftCleaner.removeVerifiedCacheEntries(inventory)
                let estimate = ByteCountFormatter.string(
                    fromByteCount: result.estimatedBytes, countStyle: .file
                )
                remoteMessages[bundleID] = "Airlift accepted " +
                    "\(result.acceptedRemovals) exact deletions (" +
                    "\(estimate) estimated, not independently remeasured). " +
                    result.failures.joined(separator: "; ")
                remoteInventories.removeValue(forKey: bundleID)
                FilzaDiagnosticsAppend(
                    "Cleaner", "Airlift \(bundleID): " + (remoteMessages[bundleID] ?? "")
                )
            } catch {
                remoteMessages[bundleID] = error.localizedDescription
                FilzaDiagnosticsAppend(
                    "Cleaner", "Airlift cleanup \(bundleID) failed: \(error.localizedDescription)"
                )
            }
            remoteBusyBundle = nil
        }
    }

'''
s=s[:start]+section+s[end:]
f.write_text(s, encoding="utf-8")

# Never show successful local cleaning for a bundle whose MCM re-activation
# fails after a first verified open. Use the exact scanned root.
replace_one(cleaner,
    """                    activateContainer: { application in
                    var activationError: NSString?
                        return MCMActivateContainerPath(
                        2,
                            application.bundleID,
                        false,
                        &activationError
                        )
                    },""",
    """                    activateContainer: { application in
                        if ContainerStore.isApplicationContainerPath(application.containerPath),
                           FileManager.default.isReadableFile(atPath: application.containerPath) {
                            return application.containerPath
                        }
                        var activationError: NSString?
                        return MCMActivateContainerPath(
                            2, application.bundleID, false, &activationError
                        )
                    },""")

replace_one(cleaner,
    """                guard let containerPath = ContainerStore.resolveAppContainerPath(
                    bundleID: record.app.bundleID
                ) else {""",
    """                let alreadyVerified = record.app.containerPath
                let containerPath = ContainerStore.isApplicationContainerPath(alreadyVerified)
                    && FileManager.default.isReadableFile(atPath: alreadyVerified)
                    ? alreadyVerified
                    : ContainerStore.resolveAppContainerPath(bundleID: record.app.bundleID)
                guard let containerPath else {""")

replace_one(cleaner,
    """                isScanning = false
                log(
                    "cleaner: scan complete bundles=\(processedCount) " +
                        "reclaimableApps=\(discoveredRecords.count)"
                )""",
    """                isScanning = false
                localScanSummary = "Local scan: \(processedCount) eligible roots; " +
                    "\(discoveredRecords.count) with accessible disposable files. " +
                    "Other app caches require a verified Airlift or sandbox grant."
                FilzaDiagnosticsAppend("Cleaner", localScanSummary)
                log("cleaner: " + localScanSummary)""")

replace_one(cleaner,
    """                selectedBundleIDs.removeAll()
                isCleaning = false
                activeAlert = .result(message: resultMessage)""",
    """                selectedBundleIDs.removeAll()
                isCleaning = false
                lastLocalCleanup = "Local clean removed \(removedItems) items, " +
                    "freed \(sizeText(freedBytes)); " +
                    "\(failedItems) failures and \(unavailableApps) unavailable roots."
                FilzaDiagnosticsAppend("Cleaner", lastLocalCleanup)
                activeAlert = .result(message: resultMessage)""")

# Refresh the remote catalog every time the user presses Scan Again too, not
# only once when Cleaner first appears. This is necessary if the user pairs in
# Settings after opening Cleaner, and works independently of local MCM access.
replace_one(cleaner,
    """    private func reload() {
        guard !isBusy else { return }""",
    """    private func reload() {
        guard !isBusy else { return }
        airliftCatalog.refresh()
        FilzaDiagnosticsAppend("Cleaner", "Refreshing local installed-app and paired Airlift catalogs")""")

# The local scan always probes all API/MCM/LS candidates, not Filza alone.
text = f.read_text(encoding="utf-8")
assert "FILZA_ALL_APP_AIRLIFT_CLEANER" in text
assert "ForEach(airliftCatalog.apps)" in text
assert "FilzaAirliftCleaner.inspect(app)" in text
assert "FilzaAirliftCleaner.removeVerifiedCacheEntries(inventory)" in text
assert "alreadyVerified = record.app.containerPath" in text
assert "NSHomeDirectory()" not in text
assert "FilzaAirliftWorkspaceView" not in text
print("All-app Cleaner: verified local roots plus per-app Airlift inspection/confirmed cache deletion")
