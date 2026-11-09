#!/usr/bin/env python3
"""Verify upstream GPLv3 sources, signing template and genuine bridge routing."""
import plistlib
import subprocess
from pathlib import Path

FILES = {
    "worse_query.m": "cba035acba4c7a5cdaf3d33024e9198dd40f04ef",
    "worse_query.h": "0275bb9959889f266ec4601c64aa55ec821dca13",
    "pathleak.m": "80de585156d02ebb8c654d12a4dc4ca8599eaed9",
    "pathleak.h": "538eef8a2b1e5370f605cc42fc484c5ba1c626ce",
    "LICENSE": "f288702d2fa16d3cdf0035b15a9fcbc552cd88e7",
    "README.md": "11591dbec0a2715360c20550ec177a9fe01856b9",
}
for filename, expected in FILES.items():
    p = Path("ThirdParty/worse_query") / filename
    assert p.is_file(), p
    actual = subprocess.check_output(["git", "hash-object", str(p)], text=True).strip()
    assert actual == expected, (filename, actual, expected)
with open("Signing/Filza27WorseQuery.entitlements", "rb") as stream:
    ent = plistlib.load(stream)
assert ent["com.apple.security.application-groups"] == [
    "group.com.filza27.nigtvibes33.worsequery"
]
make = Path("Makefile").read_text()
# Theos parse-swiftc-output only accepts length-prefixed JSON, so never
# insert swiftc -v version banners into its machine-readable stream.
assert "FilzaApplySandboxExt_SWIFTFLAGS += -v " not in make
assert "ThirdParty/worse_query/worse_query.m" in make
assert "ThirdParty/worse_query/pathleak.m" in make
assert "FilzaWorseQueryBridge.m" in make
assert "$(BAD_QUERY_ROOT)/bad_query/bad_query.c" in make
network = Path("FilzaByeTunesNetwork.mk").read_text()
assert "scripts/patch-3105-worse-query.py" in network
assert "FZWorseQueryGrantDirectory" in Path("Tweak.m").read_text()
assert "FZWorseQueryResolveAppDataContainer" in Path("MCMFilzaIntegration.m").read_text()
assert "FilzaWorseQueryBridge.h" in Path("FilzaApplySandboxExt-Bridging-Header.h").read_text()
bridge = Path("FilzaWorseQueryBridge.m").read_text()
assert "worse_query(target, groupID, alternateFlags, false)" in bridge
assert "FZWQInstalledGroup(void)" in bridge
assert "FZWorseQueryInstalledGroupIdentifier(void)" in bridge
assert "FZWorseQueryInstalledGroupIdentifier(void)" in Path("FilzaWorseQueryBridge.h").read_text()
assert "FilzaSideStoreSigningHostFactory" in Path("FilzaUnifiedPairing.swift").read_text()
assert "SideStore App Group" in Path("FilzaSSHPreferencesV2.m").read_text()
assert "containerURLForSecurityApplicationGroupIdentifier:groupID" in bridge
assert "group.com.filza27.nigtvibes33.worsequery" in bridge
assert "FZWQDedicatedEmptyCaches" in bridge
assert "FZWQCacheRestored(groupID, &restoreReason)" in bridge
# A pending Airlift restoration is never cleared or retried here. It must
# not disable independent locally consumed worse_query sandbox extensions.
assert "filza.remoteCleanerSafetyStop.v1" not in bridge
assert "FZWorseQueryPathHasActiveGrant(NSString *path)" in bridge
assert "realpath(path.fileSystemRepresentation, resolved)" in bridge
assert "FZWorseQueryPathHasActiveGrant(NSString *path)" in Path("FilzaWorseQueryBridge.h").read_text()
assert "return FZWorseQueryPathHasActiveGrant(path);" in Path("MCMFilzaIntegration.m").read_text()
assert "filza.worseQueryCacheRestoreStop.v1" in bridge
assert "if (handle < 0)" in bridge
assert "if (handle <= 0)" not in bridge
assert "NSString *groupID = FZWQInstalledGroup()" in bridge
assert Path("scripts/sign-filza27-appgroup.sh").is_file()
assert Path(".github/workflows/sign-filza27-appgroup.yml").is_file()
assert "FILZA_APPGROUP_PROFILE_BASE64" in Path(".github/workflows/sign-filza27-appgroup.yml").read_text()
assert "--verify-signed" in Path("scripts/sign-filza27-appgroup.sh").read_text()
workflow = Path(".github/workflows/diagnose-full-build.yml").read_text()
assert "codesign --force --sign - --timestamp=none --generate-entitlement-der" in workflow
assert "scripts/verify-sidestore-payload.py" in workflow
assert Path("scripts/verify-sidestore-payload.py").is_file()
print("Pinned worse_query + SideStore entitlement request and runtime group resolution PASS")
