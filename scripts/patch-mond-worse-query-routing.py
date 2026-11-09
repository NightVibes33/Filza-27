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
assert 'func grant_mg() -> Int64 {' in text
assert 'MondEmbeddedParity.defaults' in text
assert 'FZWorseQueryGrantDirectory' not in (upstream / "exploit/unsbx.swift").read_text()
unsbx.write_text(text)
poster.write_text(ptext)
print("GREEN: Mond pinned bad_query/CMG intact; verified WQ app/PB fallback")
