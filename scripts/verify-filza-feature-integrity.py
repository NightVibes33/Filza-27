#!/usr/bin/env python3
"""Source safety + full-app contract. Not a substitute for iPhone runtime tests."""
from pathlib import Path

def read(name):
    p = Path(name)
    assert p.is_file(), f"Missing integrated component: {name}"
    return p.read_text(encoding="utf-8")

make = read("Makefile")
network = read("FilzaByeTunesNetwork.mk")
remote = read("FilzaAirliftBackend.swift")
export = read("scripts/patch-3105-ipa-export.sh")
clean = read("scripts/patch-3105-cleaner-all-apps.py")
airlift_patch = read("scripts/patch-3105-airlift.py")
# Every subsystem below is part of Filza; no "only Cleaner" shortcuts.
components = {
    "native Filza": ["Tweak.m", "FilzaMainToolbarGestalt.m", "MCMFilzaIntegration.m"],
    "3105 UI and Apps Manager": ["Filza3105Host.swift", "scripts/patch-3105-app-manager-view-sort.sh",
        "scripts/patch-3105-ipa-export.sh", "ThirdParty/3105/Sources/FilzaAppIPAExporter.swift"],
    "Cleaner and Wallpapers": ["scripts/patch-3105-cleaner-all-apps.py",
        "ThirdParty/3105/Sources/LimitedCleanerService.swift", "FilzaErosionPosterBoardWriter.swift"],
    "NFCARD and pairing": ["FilzaNFCARDHost.swift", "FilzaUnifiedPairing.swift",
        "scripts/stage-nfcard.sh", "scripts/patch-nfcard-unified-pairing.py"],
    "Airlift": ["FilzaAirliftBackend.swift", "FilzaAirliftIPAExporter.swift",
        "FilzaNativeAirliftFolderBridge.swift", "FilzaAirliftCleaner.swift"],
    "worse_query and bad_query": ["FilzaWorseQueryBridge.m",
        "ThirdParty/worse_query/worse_query.m", "scripts/verify-worse-query.py"],
    "IPA decryption": ["FilzaFairPlayBackend.swift", "FilzaFairPlayRuntime.c"],
    "Mond and Gestalt": ["FilzaMondCurrentHost.swift", "FilzaMondBridge.m", "GestaltManager.m"],
    "ByeTunes": ["ByeTunesEmbeddedHost.swift", "ByeTunesMusicBridge.m"],
    "WebDAV": ["WebDAVRuntimeFix.m", "WebDAVToggleStateFix.m"],
    "SSH and SFTP": ["FilzaSSHPreferencesV2.m"],
    "CoreMedia and system browsing": ["FilzaNativeCoreMediaBridge.swift", "FilzaCoreMediaReader.swift"],
    "Signing": ["scripts/verify-sidestore-payload.py", "Signing/Filza27WorseQuery.entitlements"],
}
for component, paths in components.items():
    for path in paths: read(path)
    print("source present:", component)

assert "FilzaNFCARDHost.swift" in make
assert "FilzaAirliftBackend.swift" in make
assert "FilzaFairPlayRuntime.c" in make
assert "FilzaCoreMediaReader.swift" in make
assert "FilzaWorseQueryBridge.m" in make
assert "FilzaErosionPosterBoardWriter.swift" in make
assert "FilzaAirliftCleaner.swift" in make
assert "FilzaUnifiedPairing.swift" in make
assert "scripts/patch-mond-worse-query-routing.py" in network
assert "FZWorseQueryGrantDirectory" in read("scripts/patch-mond-worse-query-routing.py")
assert "matching.count == 1" in read("FilzaAirliftIPAExporter.swift")
assert "let metadataWQ = metadataHandle < 0" in read("scripts/patch-3105-worse-query.py")
assert "let verifiedWQ = handle < 0" in read("scripts/patch-3105-worse-query.py")
assert "scripts/patch-3105-ipa-export.sh" in network
assert "scripts/patch-3105-cleaner-all-apps.py" in network
assert "scripts/patch-3105-erosion-features.py" in network

for action in ("writeFolder", "removeRemote", "writeFile"):
    start = remote.index("static func " + action + "(")
    block = remote[start:remote.index("\n    }", start)]
    assert "try requireSafeRemoteMutation()" in block, action + " ignores restoration stop"
assert "A previous read did not confirm original-folder restoration" in remote
assert "static func snapshot(path original: String, folder: Bool)" in remote
assert "if restorationStopped {" in remote
assert "recordRestoreIncident(detail)" in remote

assert "Prepare with paired Airlift" in export
assert "pairedPrepareCandidate" in export
assert "pairedPrepareCandidate = app" in export
assert 'Label("Prepare with paired Airlift"' not in export
assert 'private func prepareIPAViaAirlift(_ app: InstalledApp)' in export
local = export.split("private func prepareIPA(_ app: InstalledApp) {", 1)[1].split(
    "private func prepareIPAViaAirlift", 1)[0]
assert "FilzaAppIPAExporter.repackage" in local
assert "FilzaAirliftIPAExporter.export" not in local, "Unsafe automatic paired fallback returned"
paired = export.split("private func prepareIPAViaAirlift(_ app: InstalledApp)", 1)[1]
assert "guard !FilzaAirlift.restorationStopped else {" in paired
assert "FilzaAirliftIPAExporter.export(paired)" in paired
assert "SAFETY STOP" in paired

assert "FILZA_MAIN_CLEANER_PARITY" in clean
assert "NSHomeDirectory()" in clean
assert "MCMActivateContainerPath" in clean
assert "FZWorseQueryGrantDirectory(candidate)" in clean
assert "No Accessible Caches Verified" in clean
assert "Catalog counts: API=" in clean
# The patch deliberately quotes forbidden names as regression assertions;
# their presence in the Python patch does NOT mean the resulting Swift UI
# contains the forbidden views.
assert "assert name not in view" in clean
assert "for name in (" in clean
assert "assert 'Text(airliftCatalog.message)' not in s" in airlift_patch
assert "mergedWithAirlift" in airlift_patch
assert "FilzaAirliftWorkspaceView(" not in airlift_patch
assert "kRequiredIdentifier" in read("MCMFilzaIntegration.m")
assert "MCMInstallStandardSandboxRoot()" in read("MCMFilzaIntegration.m")
assert "FZWQCacheRestored" in read("FilzaWorseQueryBridge.m")
print("PASS: full source-feature inventory and safety invariants.")
print("NOT PROVEN: third-party app access, restore success, device signing, runtime UI parity.")
