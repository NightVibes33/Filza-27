# Filza 27: activate the worse_query App Group

The source code and the unsigned IPA already contain the real worse_query backend. Apple will only let an installed app use its App Group when the **code signature and provisioning profile** both authorize it.

## Developer configuration

1. On the Apple Developer team that owns the explicit app ID `com.filza27.nigtvibes33`, register the App Group `group.com.filza27.nigtvibes33.worsequery` and enable it for that app ID.
2. Regenerate a valid Apple Development or Ad Hoc provisioning profile for that app ID, with the App Group included. Include the target iPhone's UDID if the profile requires registered devices.
3. Export the matching Apple code-signing certificate **with private key** as a password-protected P12.
4. In GitHub repository **Settings > Secrets and variables > Actions**, configure these four secrets:
   - `FILZA_SIGNING_P12_BASE64`: base64-encoded P12 bytes
   - `FILZA_SIGNING_P12_PASSWORD`: P12 export password
   - `FILZA_APPGROUP_PROFILE_BASE64`: base64-encoded .mobileprovision bytes
   - `FILZA_SIGNING_IDENTITY`: the exact matching codesign identity name or SHA-1
5. Every green **Verify Filza 27 arm64 IPA** build now signs and uploads **Filza-27-AppGroup-signed-arm64** automatically when all four secrets are configured. The unsigned IPA remains available separately. You can also run **Sign Filza 27 with real App Group** manually against a successful unsigned run after the manual workflow is available from the default branch.

The signing job validates the explicit app ID, TeamIdentifier, unexpired Apple profile, App Group and resulting app code signature. It signs the embedded frameworks and the Filza app, packages the new signed `filza27.ipa`, and uploads it only if verification succeeds.

The normal GitHub **unsigned** `filza27.ipa` cannot enable App Groups. An entitlement template placed in a ZIP has no authority on iOS. The signed workflow must use your own Apple Developer team. No signing keys or mobileprovision bytes belong in commits or chat messages.

Even a correctly signed build still needs an on-device `worse_query` grant/read test. Signing doesn't guarantee a sandbox exploit works on a particular iOS version. Stop remote access if a prior restoration safety stop is unresolved.
