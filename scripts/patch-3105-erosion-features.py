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

# Main Cleaner UI untouched. Erosion remains available to Wallpaper Lab and native Filza.

wallpaper = "ThirdParty/3105/Sources/WallpaperLabView.swift"
patch(wallpaper, [
    (
        "    @State private var hasLoaded = false",
        """    @State private var hasLoaded = false
    // FILZA_EROSION_WALLPAPER_BRIDGE
    @State private var confirmAirliftApply = false"""
    ),
    (
        """        Button {
            if let selectedPackage {
                alert = WallpaperLabAlert(kind: .install(selectedPackage))
            }
        } label: {""",
        """        Button {
            if let selectedPackage {
                if report?.canInstall == true {
                    // Preserve the original 3105/MCM/bad_query install path.
                    alert = WallpaperLabAlert(kind: .install(selectedPackage))
                } else if FilzaAirlift.pairedRecord() != nil {
                    // The old OS-specific MCM route is unavailable. Present
                    // the paired Airlift confirmation; never write silently.
                    confirmAirliftApply = true
                }
            }
        } label: {"""
    ),
    (
        "        .disabled(selectedPackage == nil || report?.canInstall != true || isBusy)",
        """        .disabled(selectedPackage == nil || isBusy ||
                  (report?.canInstall != true && FilzaAirlift.pairedRecord() == nil))"""
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
                "Apply wallpaper using paired access?",
                isPresented: $confirmAirliftApply,
                titleVisibility: .visible
            ) {
                Button("Apply using paired access", role: .destructive) {
                    if let package = selectedPackage { applyViaAirlift(package) }
                }
            } message: {
                Text("This writes selected wallpaper descriptors to PosterBoard " +
                     "through the paired service. It requires LocalDevVPN " +
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
                Label("Apply selected pack using paired access",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(selectedPackage == nil || isBusy ||
                      FilzaAirlift.pairedRecord() == nil)
            if FilzaAirlift.pairedRecord() == nil {
                Text("Pair via NFCARD and enable LocalDevVPN first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The main Install button uses 3105's local MCM/bad_query " +
                     "route where writable. When it is unavailable, Install " +
                     "offers this paired Airlift route with explicit confirmation. " +
                     "You can also choose Airlift manually from this section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Additional install method")
        }
    }

    private func applyViaAirlift(_ package: WallpaperStagedPackage) {
        FilzaDiagnosticsAppend(
            "WallpaperLab",
            "User selected Airlift PosterBoard install; original MCM/bad_query route retained"
        )
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.installing"
        Task {
            do {
                let count = try await FilzaErosionPosterBoardWriter.apply(
                    payload: package.payload,
                    preferredGeneration: report?.layout.generation
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

# The upstream 3105 wallpaper view uses a private log sink. Mirror exact
# access and install failures to Filza's exportable Runtime.log.
patch(wallpaper, [
    (
        '                    log("wallpaper: probe failed \\(error.localizedDescription)")',
        '''                    log("wallpaper: probe failed \\(error.localizedDescription)")
                    FilzaDiagnosticsAppend("WallpaperLab",
                        "PosterBoard local access probe failed: " + error.localizedDescription)'''
    ),
    (
        '                    log("wallpaper: install failed \\(error.localizedDescription)")',
        '''                    log("wallpaper: install failed \\(error.localizedDescription)")
                    FilzaDiagnosticsAppend("WallpaperLab",
                        "3105 local wallpaper install failed: " + error.localizedDescription)'''
    )
], "PosterBoard local access probe failed:")
