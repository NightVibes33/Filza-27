# Filza 27 — Mond 2.2 + iOS 16 Support

This release keeps the existing Filza/3105/ByeTunes/WebDAV/SSH feature set while upgrading the full modern build to pinned **Mond 2.2** and adding a separately verified **iOS 16.1+ compatibility IPA**.

## Downloads

- `Filza-27.ipa` — full modern build with Mond 2.2. Minimum iOS version: **17.0**.
- `Filza-27-iOS16.ipa` — compatibility build for **iOS 16.1+**. It keeps Filza, 3105, ByeTunes, SSH/WebDAV, and the native Gestalt Manager, but intentionally omits Mond's iOS 27-specific exploit payload.

Each IPA is built and verified independently from the exact same commit before the release workflow publishes either one.

## Mond 2.2

- Updated the embedded Mond integration to upstream commit `3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- Retained the exact upstream source snapshot under `ThirdParty/mond-current/Upstream` for provenance.
- Added the new **CacheExtra Fields** editor introduced by Mond 2.2.
- Added the upstream **Persist after reboot** setting.
- Added the upstream **Ignore exploit failure** setting.
- Included the current MobileGestalt persistence changes and corrected iOS 27 region-key behavior from the pinned upstream revision.
- Preserved MobileGestalt, PosterBoard/Tendies, HouseArrest/Santander, Run Exploit, and Generate Token flows.
- Preserved PartyUI and ZIPFoundation at their existing pinned revisions.
- Updated the embedded resource bundle identity to report Mond **2.2** while retaining the upstream artwork and `com.roooot.mond` defaults domain.
- Added a narrow generated-copy compatibility binding for Mond 2.2's new CacheExtra editor so its respring action receives the same shared `AppState` environment as the rest of the embedded Mond UI. The untouched upstream snapshot is not modified.
- Kept the generated symbol/module namespace isolation required for Mond to coexist inside Filza's process.

## iOS 16.1+ compatibility

The project now has an explicit iOS 16 source graph instead of pretending newer-only components can run there.

The iOS 16 build keeps:

- Filza core file browser
- 3105 Apps Manager and Patches
- 3105 IPA repackaging support
- ByeTunes
- SSH server
- WebDAV server
- native Gestalt Manager
- Home Screen quick actions

For iOS 16, Gestalt actions route to the native Gestalt Manager. Mond's Swift/C payload is excluded because upstream Mond targets iOS 17+ and its current access backend is designed for supported iOS 27 beta builds.

The compatibility IPA is compiled with an iOS **16.1** deployment target and packaged with `MinimumOSVersion = 16.1`. The full Mond IPA is explicitly packaged with `MinimumOSVersion = 17.0` so an incompatible modern build is not presented as an iOS 16 binary.

## Build and verification

- CI independently builds the iOS 16.1 arm64 compatibility graph and the full Mond 2.2 arm64 graph.
- The Mond verifier checks the complete pinned 2.2 functional source graph, including the new `mobilegestalt/CEView.swift` and moved `mobilegestalt/GestaltView.swift` files.
- Mond staging and verification are separated so the verifier is side-effect free and cannot silently fetch or mutate sources.
- The full build verifies the Mond 2.2 host, CacheExtra editor, persistence settings, region key, 3105, ByeTunes, SSH, and WebDAV symbols before packaging.
- The iOS 16 build verifies that Mond host symbols are absent while 3105, ByeTunes, and native Gestalt symbols remain present.
- The release workflow waits for both exact-SHA verification workflows before publishing.
- Releases include separate SHA-256 checksum files for both IPA variants.

## Compatibility note

The project does **not** claim a full jailbreak, kernel read/write, root shell, SPTM bypass, or writable system volume. Actual filesystem/container access depends on the iOS build and the access primitives available to the running app.

Mond's current exploit support remains version-specific. The iOS 16 compatibility build therefore does not label the Mond iOS 27 backend as usable on older systems; it uses the native Gestalt path instead.
