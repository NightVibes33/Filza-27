#!/usr/bin/env python3
"""Reapply the additive Airlift catalog route after 3105 upstream restaging.

3105's upstream sources are overwritten by stage-3105-v1.sh on each build.
The transformation is checked and idempotent, so the older local discovery
and UI remain intact while paired-device app metadata augments the list.
"""
from pathlib import Path

p = Path("ThirdParty/3105/Sources/AppDataBrowserView.swift")
s = p.read_text(encoding="utf-8")

def change(old, new):
    global s
    if new in s:
        return
    found = s.count(old)
    if found != 1:
        raise SystemExit(f"Airlift 3105 integration anchor changed ({found}): {old[:70]}")
    s = s.replace(old, new, 1)

change(
    "    @State private var apps: [InstalledApp] = []",
    """    @ObservedObject private var airliftCatalog = FilzaAirliftCatalogStore.shared
    @State private var pendingSnapshot: FilzaAirliftApp?
    @State private var snapshotBusy = false
    // Keep the 3105 catalog separate so a second Airlift scan cannot
    // accidentally keep stale remote-only rows from an earlier pairing.
    @State private var localAppResults: [InstalledApp] = []
    @State private var apps: [InstalledApp] = []""",
)
change(
    """                if !hasLoaded {
                    hasLoaded = true
                    reload()
                }""",
    """                if !hasLoaded {
                    hasLoaded = true
                    reload()
                }""",
)
change(
    """            .navigationDestination(for: FileBrowserDestination.self) { destination in""",
    """            .onReceive(airliftCatalog.$apps) { incoming in
                // @Published emits before its stored property is replaced.
                // Use the incoming value, or the UI can show the previous
                // (possibly empty) Erosion InstallationProxy result.
                apps = mergedWithAirlift(localAppResults, discovered: incoming)
            }
            .confirmationDialog(
                "Stage this application's files in Filza 27?",
                isPresented: Binding(
                    get: { pendingSnapshot != nil },
                    set: { if !$0 { pendingSnapshot = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let request = pendingSnapshot {
                    Button("Stage snapshot in Filza 27") {
                        pendingSnapshot = nil
                        stageInNativeFilza(request)
                    }
                }
                Button("Cancel", role: .cancel) { pendingSnapshot = nil }
            } message: {
                Text("Airlift can temporarily move device files while staging a snapshot. It must restore them successfully. A returned path alone does not grant direct filesystem access.")
            }
            .navigationDestination(for: FileBrowserDestination.self) { destination in""",
)
change(
    """                    if app.containerPath.isEmpty {
                        appRow(app)
                    } else {""",
    """                    if app.containerPath.isEmpty {
                        if let remote = airliftCatalog.apps.first(where: {
                            $0.bundleID == app.bundleID &&
                            ($0.dataPath != nil || $0.bundlePath != nil)
                        }) {
                            Button {
                                pendingSnapshot = remote
                            } label: {
                                appRow(app)
                            }
                            .buttonStyle(.plain)
                            .disabled(snapshotBusy)
                        } else {
                            appRow(app)
                        }
                    } else {""",
)

change(
    "    private func reload() {",
    """    // Paired data is staged into native Filza's Device Storage. This view
    // never mounts another 3105/Airlift file browser.
    private func stageInNativeFilza(_ app: FilzaAirliftApp) {
        guard !snapshotBusy else { return }
        guard let remotePath = app.dataPath ?? app.bundlePath else {
            ipaExportError = "InstallationProxy returned no readable path for this app."
            return
        }
        snapshotBusy = true
        Task {
            do {
                _ = try await FilzaAirlift.snapshot(path: remotePath, folder: true)
                ipaExportError = "Snapshot staged. Open the original Filza 27 file browser → Device Storage → [Airlift] Snapshots."
                FilzaDiagnosticsAppend("3105", "Native Filza snapshot saved for \(app.bundleID)")
            } catch {
                ipaExportError = "Airlift snapshot failed: \(error.localizedDescription)"
                FilzaDiagnosticsAppend("3105", "Airlift native snapshot failed \(app.bundleID): \(error.localizedDescription)")
            }
            snapshotBusy = false
        }
    }

    // Metadata never implies direct private-container filesystem access.
    // Remote metadata appears in the list; native Filza owns actual file browsing.
    private func mergedWithAirlift(
        _ localApps: [InstalledApp], discovered: [FilzaAirliftApp]? = nil
    ) -> [InstalledApp] {
        var result = localApps
        var present = Set(localApps.map(\\.bundleID))
        for remote in (discovered ?? airliftCatalog.apps) where present.insert(remote.bundleID).inserted {
            result.append(InstalledApp(
                bundleID: remote.bundleID,
                name: remote.name,
                containerPath: "",
                version: "",
                icon: nil
            ))
        }
        result.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return result
    }

    private func reload() {""",
)
for old, new in (
    ("                apps = preliminary", "                localAppResults = preliminary\n                apps = mergedWithAirlift(preliminary)"),
    ("                    apps = progressiveResult", "                    localAppResults = progressiveResult\n                    apps = mergedWithAirlift(progressiveResult)"),
    ("                apps = result", "                localAppResults = result\n                apps = mergedWithAirlift(result)"),
):
    change(old, new)

# Every explicit Refresh also re-queries InstallationProxy. A first launch
# without a pairing file no longer permanently suppresses Airlift discovery.
change(
    """        errorMessage = nil
        let emptyMessage = language.text("browser.empty")""",
    """        errorMessage = nil
        airliftCatalog.refresh()
        let emptyMessage = language.text("browser.empty")""",
)

# Main-branch parity: appRows must stay the original installed-app list.
# Airlift extends discovery and native Filza snapshot access as a backend,
# not as a connection-status row, another section or a separate browser.
assert '    private var appRows: some View {\n        List {' in s
assert 'Text(airliftCatalog.message)' not in s
p.write_text(s, encoding="utf-8")
print("GREEN: original 3105 Apps Manager rows preserved; Airlift augments metadata only")
