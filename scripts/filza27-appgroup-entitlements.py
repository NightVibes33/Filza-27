#!/usr/bin/env python3
"""Validate Apple's provisioned App Group against the final code signature."""
import argparse
import datetime
import hashlib
import plistlib
from pathlib import Path

BUNDLE = "com.filza27.nigtvibes33"
GROUP = "group.com.filza27.nigtvibes33.worsequery"
KEY = "com.apple.security.application-groups"
TEMPLATE = Path("Signing/Filza27WorseQuery.entitlements")

def check(ok, what):
    if not ok:
        raise SystemExit("Filza 27 App Group signing error: " + what)

def load(path):
    data = Path(path).read_bytes()
    start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"bplist00")
    check(start >= 0, "missing plist data: " + str(path))
    return plistlib.loads(data[start:])

def check_group(ent):
    check(isinstance(ent, dict), "missing entitlements dictionary")
    check(isinstance(ent.get(KEY), list) and GROUP in ent[KEY],
          "profile or signed app does not authorize " + GROUP)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--prepare", nargs=2, metavar=("PROFILE_PLIST", "OUTPUT_ENTITLEMENTS"))
    p.add_argument("--check-certificate", nargs=2, metavar=("PROFILE_PLIST", "CERT_SHA1"))
    p.add_argument("--verify-signed")
    args = p.parse_args()
    check(load(TEMPLATE).get(KEY) == [GROUP], "template App Group mismatch")
    if args.prepare:
        profile = load(args.prepare[0])
        ent = profile.get("Entitlements", {})
        check_group(ent)
        team_ids = profile.get("TeamIdentifier", [])
        check(isinstance(team_ids, list) and len(team_ids) == 1, "TeamIdentifier missing or ambiguous")
        team = team_ids[0]
        app_id = team + "." + BUNDLE
        check(ent.get("application-identifier") == app_id,
              "provisioning profile does not have the explicit Filza 27 app ID")
        check(ent.get("com.apple.developer.team-identifier") == team,
              "provisioning team ID does not match")
        expiration = profile.get("ExpirationDate")
        check(isinstance(expiration, datetime.datetime) and
              expiration > datetime.datetime.utcnow(), "profile expired")
        check(bool(profile.get("DeveloperCertificates")), "profile has no developer signing certificates")
        effective = {"application-identifier": app_id,
                     "com.apple.developer.team-identifier": team,
                     KEY: [GROUP]}
        for extra in ("get-task-allow", "keychain-access-groups"):
            if extra in ent:
                effective[extra] = ent[extra]
        Path(args.prepare[1]).write_bytes(plistlib.dumps(effective, sort_keys=True))
        print("Provisioning profile App Group, exact Filza ID and Team verified.")
    elif args.check_certificate:
        profile = load(args.check_certificate[0])
        sha1 = args.check_certificate[1].strip().upper()
        check(len(sha1) == 40 and all(c in "0123456789ABCDEF" for c in sha1),
              "invalid SHA-1 certificate identity")
        approved = {hashlib.sha1(cert).hexdigest().upper()
                    for cert in profile.get("DeveloperCertificates", [])}
        check(sha1 in approved, "the P12 signing certificate is NOT authorized by this profile")
        print("P12 certificate fingerprint matches DeveloperCertificates in the profile.")
    elif args.verify_signed:
        ent = load(args.verify_signed)
        check_group(ent)
        team = ent.get("com.apple.developer.team-identifier")
        check(isinstance(team, str) and
              ent.get("application-identifier") == team + "." + BUNDLE,
              "signed application identifier does not match the registered Filza ID")
        print("The final Filza code signature contains the authorized App Group.")
    else:
        print("App Group signing template validated. This does NOT grant an unsigned IPA access.")

if __name__ == "__main__":
    main()
