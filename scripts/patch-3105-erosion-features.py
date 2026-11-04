#!/usr/bin/env python3
"""Expose verified Erosion routes from embedded 3105 without faking privileges.

Erosion's InstallationProxy scanner returns metadata, not a sandbox grant.
The 3105 Cleaner keeps its existing descriptor-safe local cache deletion.
The additional Airlift browser is snapshot-only. Wallpaper Lab can explicitly
attempt Erosion's remote descriptor injection after user confirmation.
"""
from pathlib import Path

def patch(path, replacements, marker):
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if marker in text:
        print(f"Already installed: {file}")
        return
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            raise SystemExit(
                f"Erosion 3105 patch: {file} anchor changed ({count}): {old[:70]}"
            )
        text = text.replace(old, new, 1)
    if marker not in text:
        raise SystemExit(f"Erosion 3105 patch: {file} missing marker")
    file.write_text(text, encoding="utf-8")
    print(f"Patched {file}")

cleaner = "ThirdParty/3105/Sources/CleanerView.swift"
patch(cleaner, [
    (
        "    @State private var activeAlert: CleanerAlert?",
        """    @State private var activeAlert: CleanerAlert?
    // FILZA_EROSION_CLEANER_BRIDGE
    @ObservedObject private var airliftCatalog = FilzaAirliftCatalogStore.shared"""
    ),
    (
        """                hasLoaded = true
                reload()
            }""",
        """                hasLoaded = true
                reload()
                if FilzaAirlift.pairedRecord() != nil {
                    airliftCatalog.refresh()
                }
            }"""
    ),
    (
        """        if records.isEmpty {
            List { emptySection }
        } else {
            List {
                summarySection
                applicationsSection
            }""",
        """        if records.isEmpty {
            List {
                emptySection
                airliftSection
            }
        } else {
            List {
                summarySection
                applicationsSection
                airliftSection
            }"""
    ),
    (
        "    private var summarySection: some View {",
        """    // Erosion does not provide a safe system-wide cache-deletion API.
    // Show real InstallationProxy paths, but do not include them in
    // reclaimable-byte counts or the destructive local cleaner.
    private var airliftSection: some View {
        Section {
            Text(airliftCatalog.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if airliftCatalog.scanning { ProgressView() }
            ForEach(airliftCatalog.apps.filter { $0.dataPath != nil }) { app in
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.subheadline)
                    Text(app.bundleID)
                        .font(.caption2.monospaced())
                    Text("Container path discovered; native Filza owns file browsing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Erosion app containers")
        } footer: {
            Text("Airlift paths are metadata. They are not counted as " +
                 "reclaimable caches and cannot be deleted by Cleaner. " +
                 "Successful snapshots belong in Filza's native Device Storage.")
        }
    }

    private var summarySection: some View {"""
    )
], "FILZA_EROSION_CLEANER_BRIDGE")

wallpaper = "ThirdParty/3105/Sources/WallpaperLabView.swift"
patch(wallpaper, [
    (
        "    @State private var hasLoaded = false",
        """    @State private var hasLoaded = false
    // FILZA_EROSION_WALLPAPER_BRIDGE
    @State private var confirmAirliftApply = false"""
    ),
    (
        """                packagesSection
                if !activeReceipts.isEmpty { resetSection }""",
        """                packagesSection
                airliftApplySection
                if !activeReceipts.isEmpty { resetSection }"""
    ),
    (
        """            .alert(item: $alert, content: alertContent)""",
        """            .alert(item: $alert, content: alertContent)
            .confirmationDialog(
                "Apply wallpaper through Erosion/Airlift?",
                isPresented: $confirmAirliftApply,
                titleVisibility: .visible
            ) {
                Button("Apply via Airlift", role: .destructive) {
                    if let package = selectedPackage { applyViaAirlift(package) }
                }
            } message: {
                Text("This writes selected wallpaper descriptors to PosterBoard " +
                     "through the paired Erosion backend. It requires LocalDevVPN " +
                     "and may fail on this iOS build. Remote injections are not " +
                     "covered by 3105's local rollback receipts.")
            }"""
    ),
    (
        "    private var accessSection: some View {",
        """    private var airliftApplySection: some View {
        Section {
            Button {
                confirmAirliftApply = true
            } label: {
                Label("Apply selected pack via Erosion/Airlift",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(selectedPackage == nil || isBusy ||
                      FilzaAirlift.pairedRecord() == nil)
            if FilzaAirlift.pairedRecord() == nil {
                Text("Pair via NFCARD and enable LocalDevVPN first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This uses Erosion's remote PosterBoard descriptor writer " +
                     "when 3105's direct MCM access is denied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Erosion fallback")
        }
    }

    private func applyViaAirlift(_ package: WallpaperStagedPackage) {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.installing"
        Task {
            do {
                let count = try await FilzaErosionPosterBoardWriter.apply(
                    payload: package.payload
                )
                isBusy = false
                _ = openApplicationForBundleID("com.apple.PosterBoard")
                alert = WallpaperLabAlert(kind: .message(
                    titleKey: "wallpaper.install_done_title",
                    message: "Airlift confirmed " + String(count) +
                             " descriptor write(s). Open Settings > Wallpaper. " +
                             "No local 3105 rollback receipt exists for this route."
                ))
            } catch {
                isBusy = false
                FilzaDiagnosticsAppend(
                    "WallpaperLab",
                    "Erosion/Airlift apply failed: " + error.localizedDescription
                )
                alert = WallpaperLabAlert(kind: .message(
                    titleKey: "wallpaper.operation_failed",
                    message: error.localizedDescription
                ))
            }
        }
    }

    private var accessSection: some View {"""
    )
], "FILZA_EROSION_WALLPAPER_BRIDGE")
