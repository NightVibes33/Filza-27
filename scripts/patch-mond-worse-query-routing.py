#!/usr/bin/env python3
"""Preserve pinned Mond 2.2 while adding verified Filza container fallbacks."""
from pathlib import Path

root = Path("ThirdParty/mond-current/Generated/Mond")
upstream = Path("ThirdParty/mond-current/Upstream")
unsbx = root / "exploit_unsbx.swift"
poster = root / "helpers_posterboard_poster.swift"
assert upstream.is_dir() and unsbx.is_file() and poster.is_file(), "Stage Mond first"
text = unsbx.read_text()
ptext = poster.read_text()
marker = "FILZA_MOND_WQ_CONTAINER_FALLBACK"

def replace(src, before, after, description):
    count = src.count(before)
    if count != 1:
        raise SystemExit(f"Mond WQ {description}: expected 1 anchor, got {count}")
    return src.replace(before, after, 1)

if marker in text:
    assert "Filza Mond MCM/WQ resolver" in ptext
    print("Mond container fallbacks already staged")
    raise SystemExit(0)

# Preserve the original MobileGestalt bad_query and CMG implementations.
# The newer path only reports MG access when the exact Gestalt file itself
# is writable; a system-group directory sandbox extension alone is NOT enough.
text = replace(text,
    '''func grant_mg() -> Int64 {
    return grant_access(MondCurrentTweakPaths.gestalt_dir, probe_leaf: "com.apple.MobileGestalt.plist", msg: "granted mg access!")
}''',
    '''func grant_mg() -> Int64 {
    let legacy = grant_access(MondCurrentTweakPaths.gestalt_dir,
                              probe_leaf: "com.apple.MobileGestalt.plist",
                              msg: "granted mg access!")
    if legacy >= 0 { return legacy }
    // Ketamine-era bad_query is preserved. WQFiles documents a newer
    // system-group route; it is a scoped WQ fallback, not a kernel bypass.
    var mcmError: NSString?
    let groupPath = MCMActivateContainerPath(13,
        "systemgroup.com.apple.mobilegestaltcache", true, &mcmError)
    let direct = groupPath ??
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache"
    if FZWorseQueryGrantDirectory(direct) != nil &&
       FileManager.default.isWritableFile(atPath: MondCurrentTweakPaths.gestalt) {
        print("(wq) MobileGestalt file verified writable with system-group grant")
        return 0 // a logical success; never release as a bad_query handle
    }
    print("(wq) MobileGestalt path still inaccessible; retaining original error")
    return legacy
}''',
    "MobileGestalt verified WQ fallback")

# The preserved upstream method selection, MG bad_query and CMG stay unchanged.
text = replace(text,
    '        print("(bq) kernel rejected sandbox query for \(probe_dir.path)")\n        return handle',
    '''        // FILZA_MOND_WQ_CONTAINER_FALLBACK: pinned bad_query is first.
        // WQ is scoped to container directories; never label a read grant
        // as a MobileGestalt cache grant or a kernel handle.
        if FZWorseQueryGrantDirectory(container.path) != nil {
            _ = try? MondCurrentPosterBackend.ensure_directory(at: probe_dir.path)
            if FileManager.default.isWritableFile(atPath: probe_dir.path) {
                print("(wq) PosterBoard descriptor path writable")
                return 0 // Mond status, not an upstream bad_query handle
            }
        }
        print("(bq) kernel rejected sandbox query for \(probe_dir.path)")
        return handle''',
    "PosterBoard access")

text = replace(text,
    '        return handle\n    }\n\n    print("(bq) no app containers found")',
    '''        if handle < 0, FZWorseQueryGrantDirectory(target) != nil {
            print("(wq) verified app container \(target)")
            return 0 // Mond status, not a bad_query handle
        }
        return handle
    }

    // On new iOS, the old bad_query_list root enumeration can fail.
    // Installed-app metadata supplies candidates, not filesystem grants.
    for item in ContainerStore.installedAppsFromAPI()
        where item.bundleID != Bundle.main.bundleIdentifier &&
              ContainerStore.isApplicationContainerPath(item.containerPath) {
        if FZWorseQueryGrantDirectory(item.containerPath) != nil {
            print("(wq) verified app container \(item.containerPath)")
            return 0
        }
    }

    print("(bq) no app containers found")''',
    "Installed apps access")
# Mond's pinned PosterBoard backend probes generation 61 unconditionally.
# Read the real version directories first; a newer layout can otherwise make
# a working WQ grant appear to fail on iOS 27.
ptext = replace(ptext,
    '''    static func poster_extensions_root(container: URL) -> URL {
        container
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("PRBPosterExtensionDataStore")
            .appendingPathComponent(ext_version)
            .appendingPathComponent("Extensions")
    }''',
    '''    static func poster_extensions_root(container: URL) -> URL {
        let store = container
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("PRBPosterExtensionDataStore")
        // FILZA_MOND_POSTERBOARD_DYNAMIC_GENERATION: real on-device layout
        // takes precedence over Mond 2.2's historical generation 61.
        _ = FZWorseQueryGrantDirectory(store.path)
        let generations = ((try? FileManager.default.contentsOfDirectory(
            atPath: store.path
        )) ?? []).filter {
            !$0.isEmpty && $0.count <= 4 && $0.allSatisfy({ $0.isNumber })
        }.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        let selected = generations.first(where: {
            FileManager.default.fileExists(atPath: store
                .appendingPathComponent($0)
                .appendingPathComponent("Extensions").path)
        }) ?? ext_version
        if selected != ext_version {
            FilzaDiagnosticsAppend("mond",
                "PosterBoard discovered generation \(selected), not pinned 61")
        }
        return store.appendingPathComponent(selected)
            .appendingPathComponent("Extensions")
    }''',
    "dynamic PosterBoard generation")

ptext = replace(ptext, '        throw MondCurrentPosterError.container_404',
    '''        // Filza Mond MCM/WQ resolver: retain original bad_query discovery.
        // Class-2 MCM activation invokes Filza's verified WQ fallback.
        var filzaMCMError: NSString?
        if let root = MCMActivateContainerPath(2, pb_bid, false, &filzaMCMError),
           ContainerStore.isApplicationContainerPath(root) {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        throw MondCurrentPosterError.container_404''',
    "PosterBoard container resolution")
ptext = replace(ptext,
    '        guard handle >= 0 else { return nil }\n        defer { mond_bad_query_release(handle) }',
    '''        let filzaWQ = handle < 0 &&
            FZWorseQueryGrantDirectory(url.deletingLastPathComponent().path) != nil
        guard handle >= 0 || filzaWQ else { return nil }
        defer { if handle >= 0 { mond_bad_query_release(handle) } }''',
    "PosterBoard metadata")
# Keep the original backup/rollback logic, but block an empty cache write
# and give an actionable failure instead of Mond's generic pop-up.
mgpath = root / "helpers_mg.swift"
mgtext = mgpath.read_text()
mgtext = replace(mgtext, '''func mg_apply() {
    do {''',
    '''func mg_apply() {
    guard mg_dict_now.count > 0, mg_dict_now["CacheData"] != nil else {
        FilzaDiagnosticsAppend("mond", "MobileGestalt Apply refused: cache has not loaded")
        MondCurrentAlertinator.shared.alert(title: "MobileGestalt not loaded",
            body: "Reopen MobileGestalt and verify the cache loads before applying.")
        return
    }
    do {''', "unloaded MG write protection")
# Staged Mond sources can differ in alert-wrapper formatting. Match the
# actual failure print, not an incidental alert implementation detail.
mgtext = replace(mgtext,
    r'        print("(mg) failed to apply mobilegestalt: \(error)")',
    r'''        let reason = String(describing: error)
        FilzaDiagnosticsAppend("mond", "MobileGestalt Apply failed: \(reason)")
        print("(mg) failed to apply mobilegestalt: \(error)")''',
    "MG apply failure diagnostics")
mgpath.write_text(mgtext)

assert 'func grant_mg() -> Int64 {' in text
assert 'MondEmbeddedParity.defaults' in text
assert 'FZWorseQueryGrantDirectory' not in (upstream / "exploit/unsbx.swift").read_text()
unsbx.write_text(text)
poster.write_text(ptext)
print("GREEN: Mond pinned bad_query/CMG intact; dynamic PosterBoard generation and safe MG apply diagnostics")
