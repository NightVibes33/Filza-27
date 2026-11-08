#!/usr/bin/env python3
"""Route actual 3105 app/container and Cleaner fallback through genuine worse_query."""
from pathlib import Path

def patch(name: str, before: str, after: str):
    p = Path(name)
    source = p.read_text(encoding="utf-8")
    n = source.count(before)
    if n != 1:
        raise SystemExit(f"worse_query: {name} source changed ({n}): {before[:100]!r}")
    p.write_text(source.replace(before, after, 1), encoding="utf-8")

store = "ThirdParty/3105/Sources/ContainerStore.swift"
patch(store,
    "        // Fallback for iOS builds where MCM refuses to hand out sandbox",
    """        // FILZA_REAL_WORSE_QUERY_APP_ACCESS
        // Actual LS/InstallationProxy container URL, never fabricated UUID.
        if let appInfo = installedAppInfo() as? [String: [String: Any]],
           let known = appInfo[bundleID]?["container"] as? String,
           isApplicationContainerPath(known),
           let granted = FZWorseQueryGrantDirectory(known) {
            log("worse_query confirmed direct access for \(bundleID)")
            return granted
        }

        // Fallback for iOS builds where MCM refuses to hand out sandbox""")
cleaner = "ThirdParty/3105/Sources/CleanerView.swift"
patch(cleaner,
    """                        return MCMActivateContainerPath(
                            2, application.bundleID, false, &activationError
                        )
                    },""",
    """                        if let direct = MCMActivateContainerPath(
                            2, application.bundleID, false, &activationError
                        ) { return direct }
                        // The same native backend grants a real KNOWN path,
                        // then the original Cleaner validates actual caches.
                        if ContainerStore.isApplicationContainerPath(application.containerPath) {
                            return FZWorseQueryGrantDirectory(application.containerPath)
                        }
                        return nil
                    },""")
body = Path(cleaner).read_text()
assert "FILZA_UNIFIED_CLEANER_LIST_V1" in body
assert "ForEach(filteredRecords)" in body
assert "airliftSection" not in body
assert "ForEach(airliftCatalog.apps)" not in body
assert "FZWorseQueryGrantDirectory(application.containerPath)" in body
assert "FilzaAirliftCleaner.inspect(app)" in body
print("3105 unified original Cleaner + Apps Manager direct WQ fallback PASS")
