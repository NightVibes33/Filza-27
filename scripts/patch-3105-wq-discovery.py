#!/usr/bin/env python3
"""Read-only WQFiles-style dynamic discovery shared by original Filza and 3105.

The native scanner is asynchronous and scans the data volume once. Old
bad_query/MCM/LaunchServices enumeration remains the fallback everywhere.
"""
from pathlib import Path

store = Path("ThirdParty/3105/Sources/ContainerStore.swift")
browser = Path("ThirdParty/3105/Sources/AppDataBrowserView.swift")
cleaner = Path("ThirdParty/3105/Sources/CleanerView.swift")

def exactly_once(text, original, replacement, name):
    n = text.count(original)
    if n != 1:
        raise SystemExit(f"WQFiles discovery {name} changed: expected 1, got {n}")
    return text.replace(original, replacement, 1)

s = store.read_text()
s = exactly_once(
    s,
    '    static func enumerateDirectories(path: String, maxInode: Int64 = 2_000_000) -> [String] {\n',
    '''    static func enumerateDirectories(path: String, maxInode: Int64 = 2_000_000) -> [String] {
        // FILZA_WQFILES_DYNAMIC_DISCOVERY: only completed background
        // fsgetpath results; no fixed inode ceiling or guessed app rows.
        let known = FZContainerDiscoveryCachedPaths(path)
        if !known.isEmpty {
            log("WQFiles discovery: \\(known.count) candidate paths for \\(path)")
            return known
        }
''',
    "filesystem enumeration",
)
s = exactly_once(
    s,
    '    static func enumerateDirectoriesWithTraversalGrant(path: String) -> [String] {\n',
    '''    static func enumerateDirectoriesWithTraversalGrant(path: String) -> [String] {
        let discovered = FZContainerDiscoveryCachedPaths(path)
        if !discovered.isEmpty {
            log("WQFiles discovered \\(discovered.count) candidates; access checked individually")
            return discovered
        }
''',
    "traversal discovery",
)
s = exactly_once(
    s,
    '''        guard let validData = data,
              let plist = try? PropertyListSerialization.propertyList(from: validData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
''',
    '''        guard let validData = data,
              let plist = try? PropertyListSerialization.propertyList(from: validData, options: [], format: nil) as? [String: Any] else {
            // WQFiles uses the ContainerManager identifier xattr when the
            // metadata plist is root-owned. Do not fabricate a bundle ID.
            if let identifier = FZContainerDiscoveryIdentifier(containerPath),
               ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier) {
                return ContainerMetadata(bundleID: identifier, displayName: "")
            }
            return nil
        }
''',
    "metadata xattr fallback",
)
store.write_text(s)

c = cleaner.read_text()
c = exactly_once(
    c,
    '''            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reload()
            }''',
    '''            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reload()
            }
            // The background inode scan may finish after the first empty
            // Cleaner view. Refresh the original UI, not an invented list.
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("FilzaVerifiedContainerLinksReady")
            )) { _ in
                if !isBusy { reload() }
            }''',
    "cleaner refresh",
)
cleaner.write_text(c)

b = browser.read_text()
b = exactly_once(
    b,
    '            .onReceive(airliftCatalog.$apps) { incoming in',
    '''            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("FilzaVerifiedContainerLinksReady")
            )) { _ in
                if exportingBundleID == nil { reload() }
            }
            .onReceive(airliftCatalog.$apps) { incoming in''',
    "original Apps Manager refresh",
)
browser.write_text(b)
print("GREEN: original 3105 Apps Manager and Cleaner use completed WQFiles-style candidates; bad_query retained")
