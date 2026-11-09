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
# Cleaner is upgraded in the verified-root-only main UI adapter.
view = Path("ThirdParty/3105/Sources/CleanerView.swift").read_text()
assert "FILZA_MAIN_CLEANER_PARITY" in view
assert "FZWorseQueryGrantDirectory(candidate)" in view
assert "ForEach(filteredRecords)" in view
assert "allCleanerRecords" not in view
print("3105 main Cleaner and Apps Manager real worse_query routing PASS")
