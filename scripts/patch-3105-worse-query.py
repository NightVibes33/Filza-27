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
# Preserve original bad_query handles on every iOS it supports. Where it
# cannot grant a discovered UUID directory, worse_query can supply a verified
# directory grant without ever masquerading as a bad_query integer handle.
patch(store,
    "        let metadataHandle = grantContainerAccess(directMetadataPath)\n        if metadataHandle >= 0 {",
    """        let metadataHandle = grantContainerAccess(directMetadataPath)
        let metadataWQ = metadataHandle < 0 &&
            FZWorseQueryGrantDirectory(fallback.containerPath) != nil
        if metadataHandle >= 0 || metadataWQ {""")
patch(store,
    "            let metadata = readContainerMetadata(containerPath: fallback.containerPath)\n            bad_query_release(metadataHandle)",
    """            let metadata = readContainerMetadata(containerPath: fallback.containerPath)
            if metadataHandle >= 0 { bad_query_release(metadataHandle) }""")
patch(store,
    "        let handle = grantContainerAccess(fallback.containerPath)\n        guard handle >= 0 else { return nil }\n        defer { bad_query_release(handle) }",
    """        let handle = grantContainerAccess(fallback.containerPath)
        let verifiedWQ = handle < 0 &&
            FZWorseQueryGrantDirectory(fallback.containerPath) != nil
        guard handle >= 0 || verifiedWQ else { return nil }
        defer { if handle >= 0 { bad_query_release(handle) } }""")
# Cleaner is upgraded in the verified-root-only main UI adapter.
view = Path("ThirdParty/3105/Sources/CleanerView.swift").read_text()
assert "FILZA_MAIN_CLEANER_PARITY" in view
assert "FZWorseQueryGrantDirectory(candidate)" in view
assert "ForEach(filteredRecords)" in view
assert "allCleanerRecords" not in view
print("3105 main Cleaner and Apps Manager real worse_query routing PASS")
