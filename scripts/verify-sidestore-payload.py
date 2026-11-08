#!/usr/bin/env python3
"""Check the SideStore source IPA identity and ad-hoc App Group request."""
import plistlib
import subprocess
import sys
from pathlib import Path

EXPECTED_ID = "com.filza27.nigtvibes33"
EXPECTED_GROUP = "group.com.filza27.nigtvibes33.worsequery"
GROUP_KEY = "com.apple.security.application-groups"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify-sidestore-payload.py Payload/Filza.app")
    app = Path(sys.argv[1])
    assert app.is_dir(), f"Missing app: {app}"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == EXPECTED_ID, "Apple-owned/old Filza App ID in main Info.plist"
    assert info.get("CFBundleDisplayName") == "Filza 27"
    assert not list(app.rglob("*.appex")), "A legacy extension may trigger Apple's reserved MobileHouseArrest App ID"
    assert not list(app.rglob("embedded.mobileprovision")), "Public SideStore input must not carry a provisioned identity"
    assert (app / info["CFBundleExecutable"]).is_file(), "Missing Filza executable"
    assert (app / "Frameworks/FilzaApplySandboxExt.dylib").is_file()
    for nested in app.rglob("Info.plist"):
        if nested == app / "Info.plist":
            continue
        try:
            child_info = plistlib.loads(nested.read_bytes())
        except Exception:
            continue
        ident = child_info.get("CFBundleIdentifier", "")
        if child_info.get("CFBundlePackageType") in ("APPL", "XPC!", "XPC"):
            assert not ident.startswith("com.apple.mobile.MobileHouseArrest"), nested
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    data = result.stdout
    start = data.find(b"<?xml")
    if start == -1:
        start = data.find(b"bplist00")
    assert start >= 0, "No Mach-O embedded entitlement request for SideStore"
    ent = plistlib.loads(data[start:])
    assert ent.get(GROUP_KEY) == [EXPECTED_GROUP], "Wrong or missing requested SideStore App Group"
    assert "application-identifier" not in ent, "Ad-hoc request must not carry an Apple team or App ID"
    print("GREEN: Filza custom App ID, no MobileHouseArrest extensions, SideStore App Group request in signature")


if __name__ == "__main__":
    main()
