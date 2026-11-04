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
                    Button("Clean selected app", role: .destructive) {
                        remoteConfirmation = nil
                        cleanRemoteApp(bundleID)
                    }
                }
                Button("Cancel", role: .cancel) { remoteConfirmation = nil }
            } message: {
                Text("Only items confirmed in a complete paired cache snapshot " +
                     "from Library/Caches and tmp will be removed. The source app " +
                     "should be closed. Remote deletion cannot be undone; transport " +
                     "success is not proof of reclaimed bytes.")
            }""")

# One app list, not separate "local" and "Erosion" app categories.
# Real Airlift InstallationProxy discovery provides rows, not fake cache sizes.
replace_one(cleaner,
    """    private var filteredRecords: [CleanerAppRecord] {""",
    """    // FILZA_UNIFIED_CLEANER_LIST_V1
    private var allCleanerRecords: [CleanerAppRecord] {
        var known = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for remote in airliftCatalog.apps {
            guard ContainerPresentationPolicy.shouldShow(bundleID: remote.bundleID),
                  known[remote.bundleID] == nil else { continue }
            let app = InstalledApp(
                bundleID: remote.bundleID,
                name: remote.name,
                containerPath: remote.dataPath ?? "",
                version: "",
                icon: nil
            )
            // Discovery is metadata. Zero here means unknown, NOT a 0-byte scan.
            known[remote.bundleID] = CleanerAppRecord(
                app: app,
                usage: LimitedCleanerUsage(
                    cacheBytes: 0, temporaryBytes: 0, removableItemCount: 0
                )
            )
        }
        return Array(known.values)
    }

    private func isLocalEligible(_ bundleID: String) -> Bool {
        records.contains { $0.id == bundleID }
    }

    private func remoteApp(for bundleID: String) -> FilzaAirliftApp? {
        airliftCatalog.apps.first { $0.bundleID == bundleID }
    }

    private var filteredRecords: [CleanerAppRecord] {""")
replace_one(cleaner,
    """            matchingRecords = records
        } else {""",
    """            matchingRecords = allCleanerRecords
        } else {""")
replace_one(cleaner,
    """            matchingRecords = records.filter {""",
    """            matchingRecords = allCleanerRecords.filter {""")
replace_one(cleaner,
    """        if records.isEmpty {
            List { emptySection }
        } else {
            List {
                summarySection
                applicationsSection
            }
        }""",
    """        if allCleanerRecords.isEmpty {
            List { emptySection }
        } else {
            List {
                summarySection
                applicationsSection
            }
        }""")
replace_one(cleaner,
    """        if !records.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {""",
    """        if !allCleanerRecords.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {""")
replace_one(cleaner,
    """                Text(language.text("cleaner.apps_with_cache", Int64(filteredRecords.count)))""",
    """                Text("\(filteredRecords.count) installed apps")""")
replace_one(cleaner,
    """            if !records.isEmpty {
                Text(language.text("cleaner.apps_footer"))
            }""",
    """            if !allCleanerRecords.isEmpty {
                Text("Only verified caches can be cleaned. Other app containers " +
                     "are discovered, not automatically readable.")
            }""")
replace_one(cleaner,
    """                ForEach(filteredRecords) { record in
                    Button {
                        toggleSelection(record.id)
                    } label: {
                        applicationRow(record)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCleaning)
                }""",
    """                ForEach(filteredRecords) { record in
                    Button {
                        if isLocalEligible(record.id) {
                            toggleSelection(record.id)
                        } else if let remote = remoteApp(for: record.id) {
                            scanRemoteApp(remote)
                        }
                    } label: {
                        applicationRow(record)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCleaning ||
                              (!isLocalEligible(record.id) &&
                               (remoteOperationsLocked || remoteBusyBundle != nil)))
                    .contextMenu {
                        if let remote = remoteApp(for: record.id) {
                            Button {
                                scanRemoteApp(remote)
                            } label: {
                                Label("Inspect cache", systemImage: "arrow.clockwise")
                            }
                            .disabled(remoteOperationsLocked || remoteBusyBundle != nil ||
                                      remote.dataPath == nil || isBusy)
                            if let inventory = remoteInventories[record.id],
                               inventory.canClean {
                                Button(role: .destructive) {
                                    remoteConfirmation = record.id
                                } label: {
                                    Label("Clean verified cache", systemImage: "trash")
                                }
                                .disabled(remoteOperationsLocked || remoteBusyBundle != nil || isBusy)
                            }
                        }
                    }
                }""")
replace_one(cleaner,
    """                Text(record.app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)""",
    """                Text(record.app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isLocalEligible(record.id) {
                    Text(remoteMessages[record.id] ??
                         (remoteOperationsLocked ? "Recovery required before remote access" :
                          (remoteBusyBundle == record.id ? "Inspecting cache…" :
                           (remoteApp(for: record.id)?.dataPath == nil
                              ? "No data container reported"
                              : (remoteInventories[record.id]?.canClean == true
                                ? "Verified • long press to clean"
                                : "Not inspected • tap to inspect")))))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)""")
replace_one(cleaner,
    """            Text(sizeText(record.usage.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: selectedBundleIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")""",
    """            if isLocalEligible(record.id) {
                Text(sizeText(record.usage.totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let inventory = remoteInventories[record.id],
                      inventory.canClean {
                Text(sizeText(inventory.bytes) + " est.")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }

            Image(systemName: isLocalEligible(record.id)
                  ? (selectedBundleIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                  : "arrow.clockwise.circle")""")
replace_one(cleaner,
    """        } footer: {
            Text(language.text("cleaner.scope_footer"))
        }
    }""",
    """        } footer: {
            Text(language.text("cleaner.scope_footer"))
            Text(airliftCatalog.message)
                .font(.caption2)
            if airliftCatalog.scanning { ProgressView() }
            if remoteOperationsLocked {
                Text("SAFETY STOP: remote directory restoration was not confirmed. " +
                     "Remote Cleaner operations are blocked until recovery is resolved.")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }""")
replace_one(cleaner,
    """    @State private var remoteConfirmation: String?""",
    """    @State private var remoteConfirmation: String?
    @State private var remoteOperationsLocked = false""")

# Remote operations are opt-in from the SAME original Cleaner app row.
# A failed original-object restore locks the remote Cleaner for this session.
replace_one(cleaner,
    """    private var summarySection: some View {""",
    """    private func scanRemoteApp(_ app: FilzaAirliftApp) {
        guard !remoteOperationsLocked, remoteBusyBundle == nil,
              !isBusy, app.dataPath != nil else { return }
        remoteBusyBundle = app.bundleID
        remoteInventories.removeValue(forKey: app.bundleID)
        remoteMessages[app.bundleID] = "Inspecting paired cache…"
        Task {
            do {
                let inventory = try await FilzaAirliftCleaner.inspect(app)
                remoteInventories[app.bundleID] = inventory
                if !inventory.failures.isEmpty {
                    remoteMessages[app.bundleID] = inventory.failures.joined(separator: "; ")
                } else {
                    remoteMessages[app.bundleID] = inventory.entries.isEmpty
                        ? "No removable caches confirmed."
                        : "Verified • long press this app to clean."
                }
            } catch {
                remoteMessages[app.bundleID] = error.localizedDescription
                if let airliftError = error as? FilzaAirliftError,
                   case .unsafeRecovery = airliftError {
                    remoteOperationsLocked = true
                    remoteInventories.removeAll()
                }
                FilzaDiagnosticsAppend(
                    "Cleaner", "Paired scan \(app.bundleID) failed: \(error.localizedDescription)"
                )
            }
            remoteBusyBundle = nil
        }
    }

    private func cleanRemoteApp(_ bundleID: String) {
        guard !remoteOperationsLocked, remoteBusyBundle == nil,
              let inventory = remoteInventories[bundleID],
              inventory.canClean else { return }
        remoteBusyBundle = bundleID
        remoteMessages[bundleID] = "Cleaning verified cache entries…"
        Task {
            do {
                let result = try await FilzaAirliftCleaner.removeVerifiedCacheEntries(inventory)
                let estimate = ByteCountFormatter.string(
                    fromByteCount: result.estimatedBytes, countStyle: .file
                )
                remoteMessages[bundleID] = "Remote cleanup accepted " +
                    "\(result.acceptedRemovals) exact deletions (" +
                    "\(estimate) estimated, not independently remeasured). " +
                    result.failures.joined(separator: "; ")
                remoteInventories.removeValue(forKey: bundleID)
                FilzaDiagnosticsAppend(
                    "Cleaner", "Paired cleanup \(bundleID): " + (remoteMessages[bundleID] ?? "")
                )
            } catch {
                remoteMessages[bundleID] = error.localizedDescription
                if let airliftError = error as? FilzaAirliftError,
                   case .unsafeRecovery = airliftError {
                    remoteOperationsLocked = true
                    remoteInventories.removeAll()
                }
                FilzaDiagnosticsAppend(
                    "Cleaner", "Paired cleanup \(bundleID) failed: \(error.localizedDescription)"
                )
            }
            remoteBusyBundle = nil
        }
    }

    private var summarySection: some View {""")

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

# Verify merged rows are drawn only by 3105's original Cleaner app list.
text = f.read_text(encoding="utf-8")
assert "FILZA_UNIFIED_CLEANER_LIST_V1" in text
assert "allCleanerRecords" in text
assert "ForEach(filteredRecords)" in text
assert "airliftSection" not in text
assert "ForEach(airliftCatalog.apps)" not in text
assert "FilzaAirliftCleaner.inspect(app)" in text
assert "FilzaAirliftCleaner.removeVerifiedCacheEntries(inventory)" in text
assert "remoteOperationsLocked" in text
assert "alreadyVerified = record.app.containerPath" in text
assert "NSHomeDirectory()" not in text
assert "FilzaAirliftWorkspaceView" not in text
print("Unified 3105 Cleaner: single app list from local + paired discovery, no fake cache sizes")
