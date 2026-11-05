#!/usr/bin/env python3
"""Set Filza 27's unsigned app identity and remove legacy incompatible appex.

iOS requires extension bundle identifiers to begin with the signed parent ID.
The original unsigned FilzaSlop carries an Apple MobileHouseArrest share
extension; SideStore can suffix Filza's ID with a team identifier and cannot
install that Apple-owned extension. Removing it does not remove embedded
ByeTunes, NFCARD, Airlift, or 3105 modules compiled into Filza's dylib.
"""
import plistlib
import shutil
import sys
from pathlib import Path

DEFAULT_BUNDLE_ID = "com.filza27.nigtvibes33"
DEFAULT_APP_NAME = "Filza 27"
KNOWN_BASE_IDENTITIES = {"com.apple.mobile.MobileHouseArrest", DEFAULT_BUNDLE_ID}
KNOWN_SHARING_IDENTITIES = {"com.apple.mobile.MobileHouseArrest.Sharing", f"{DEFAULT_BUNDLE_ID}.Sharing"}


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <app/Info.plist>", file=sys.stderr)
        return 64
    info_file = Path(sys.argv[1])
    with info_file.open("rb") as stream:
        info = plistlib.load(stream)
    old = info.get("CFBundleIdentifier")
    if old not in KNOWN_BASE_IDENTITIES:
        print(f"Unrecognized base IPA bundle identifier: {old!r}", file=sys.stderr)
        return 65

    plugins = info_file.parent / "PlugIns"
    sharing = plugins / "Sharing.appex"
    if sharing.exists():
        extension_file = sharing / "Info.plist"
        if not extension_file.is_file():
            print("Unexpected Sharing.appex structure", file=sys.stderr)
            return 66
        with extension_file.open("rb") as stream:
            extension = plistlib.load(stream)
        if extension.get("CFBundleIdentifier") not in KNOWN_SHARING_IDENTITIES:
            print("Refusing to discard an unknown share extension", file=sys.stderr)
            return 66
        shutil.rmtree(sharing)
        print("Removed legacy MobileHouseArrest Sharing.appex")

    # An unexpected appex cannot be assumed re-signable when a signer appends
    # an identifier suffix. Fail packaging rather than produce an install error.
    if plugins.is_dir():
        unexpected = sorted(plugins.glob("*.appex"))
        if unexpected:
            print(f"Unexpected bundled app extensions: {unexpected}", file=sys.stderr)
            return 67
        if not any(plugins.iterdir()):
            plugins.rmdir()

    info["CFBundleIdentifier"] = DEFAULT_BUNDLE_ID
    info["CFBundleName"] = DEFAULT_APP_NAME
    info["CFBundleDisplayName"] = DEFAULT_APP_NAME
    with info_file.open("wb") as stream:
        plistlib.dump(info, stream, fmt=plistlib.FMT_XML, sort_keys=False)
    with info_file.open("rb") as stream:
        verified = plistlib.load(stream)
    assert verified["CFBundleIdentifier"] == DEFAULT_BUNDLE_ID
    assert verified["CFBundleDisplayName"] == DEFAULT_APP_NAME
    print(f"Unsigned Filza host: {old} -> {DEFAULT_BUNDLE_ID}, {DEFAULT_APP_NAME}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
