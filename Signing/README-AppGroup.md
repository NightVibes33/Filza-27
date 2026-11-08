# Filza 27: SideStore signing (recommended)

The downloadable Filza 27 IPA is an **ad-hoc-signed SideStore input**, not an Apple-provisioned installable IPA. Its ad-hoc Mach-O signature requests only the App Group `group.com.filza27.nigtvibes33.worsequery`. It never carries the developer's certificate, provisioning profile, or a reserved Apple App ID.

1. Download the current **filza27.ipa**, not the upstream FilzaSlop IPA. The expected `CFBundleIdentifier` is `com.filza27.nigtvibes33`; the old `com.apple.mobile.MobileHouseArrest` identifier and Sharing.appex are removed.
2. Open this IPA in SideStore and let SideStore sign and install with **the end user's own Apple ID/team**. Do not import an old Filza IPA through a cached source.
3. SideStore reads the ad-hoc entitlement request, attempts to register/assign the App Group on the user's Apple team, then generates the new provisioning profile and signs the app. It may append `.<TEAMID>` to the App Group. These operations require Apple's acceptance and must not be claimed as successful without the installed profile.
4. The Filza worse_query adapter reads the **actual signed** App Group entitlement at runtime, recognizes the exact requested group or SideStore's `.<TEAMID>` variant, validates that iOS can open its dedicated group container, and only then calls upstream worse_query.
5. Device testing is still required. App Group provisioning does not establish that worse_query grants arbitrary filesystem access.

## Troubleshooting

- **9400: `com.apple.mobile.MobileHouseArrest.<TEAMID>` unavailable:** SideStore is trying to register the original, Apple-owned FilzaSlop App ID. Discard that imported source file and import the **new filza27.ipa** directly. It must show `com.filza27.nigtvibes33` in its Info.plist. Do not attempt to register an Apple system App ID.
- **App Group registration fails:** inspect SideStore's Developer Services/App Groups and provisioning result. Apple must approve the group on the active team. The ad-hoc signature alone does not grant access.
- **Filza reports missing group:** inspect the installed signed entitlements, not the unsigned IPA template. SideStore may have stripped the request or the provisioning step may not have succeeded.

## Optional CI Apple signing (not required for SideStore users)

The original developer-owned workflow `.github/workflows/sign-filza27-appgroup.yml` remains optional. It requires an Apple Developer provisioning profile and these four GitHub Actions secrets:
`FILZA_SIGNING_P12_BASE64`, `FILZA_SIGNING_P12_PASSWORD`, `FILZA_APPGROUP_PROFILE_BASE64`, and `FILZA_SIGNING_IDENTITY`.

Do not add these credentials for ordinary SideStore distribution. The separate signed artifact and corresponding workflow are not prerequisites for the SideStore IPA. Neither signing model guarantees an iOS 27 sandbox exploit.
