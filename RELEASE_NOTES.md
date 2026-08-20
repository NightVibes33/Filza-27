# Filza 27 — Universal iOS 16.1+ + Mond 2.2

This release keeps Filza, 3105, ByeTunes, WebDAV, SSH, native Gestalt, and the full pinned Mond 2.2 integration in **one IPA**.

## Download

- `Filza-27.ipa` — one universal arm64 IPA with `MinimumOSVersion = 16.1`.
- `Filza-27-SHA256.txt` — SHA-256 checksum for that IPA.

There is no separate iOS 16 IPA.

## Universal runtime model

The IPA contains two runtime layers:

- `Frameworks/FilzaApplySandboxExt.dylib` — the core runtime compiled for **iOS 16.1+**. It contains Filza integration, 3105, ByeTunes, SSH, WebDAV, native Gestalt, and the shared routing layer.
- `Frameworks/FilzaMondModern.dylib` — the full pinned **Mond 2.2** runtime compiled for **iOS 17.0+** and bundled inside the same IPA.

The core does **not** link the Mond dylib eagerly. On iOS 17+ it lazy-loads `FilzaMondModern.dylib` from the app's Frameworks directory when Mond is opened. On iOS 16 it never loads that newer Mach-O and routes Gestalt actions to the native Gestalt Manager instead.

That keeps the application itself installable from iOS 16.1 upward without pretending Mond's iOS-17+ code is an iOS-16 binary.

## Included on iOS 16.1+

- Filza core file browser
- 3105 Apps Manager and Patches
- 3105 IPA repackaging support
- ByeTunes
- SSH server
- WebDAV server
- native Gestalt Manager
- Home Screen quick actions

## Mond 2.2 on supported newer systems

The bundled Mond runtime is pinned to upstream commit `3d91194716ad5f06afdf7e9037e6964e80a4ac29` and keeps:

- MobileGestalt
- CacheExtra Fields editor
- PosterBoard / Tendies
- HouseArrest / Santander
- Run Exploit
- Generate Token
- Persist after reboot
- Ignore exploit failure
- current MobileGestalt persistence changes
- corrected iOS 27 region-key behavior
- PartyUI and ZIPFoundation pinned dependencies
- dedicated `com.roooot.mond` defaults domain and embedded Mond resource bundle

The exact upstream source snapshot remains under `ThirdParty/mond-current/Upstream` for provenance.

## Build and verification

The universal verifier builds both pieces from the same commit and then packages them into one IPA. CI verifies:

- application `MinimumOSVersion = 16.1`
- core dylib Mach-O minimum OS = 16.1
- optional Mond dylib Mach-O minimum OS = 17.0
- the core contains no `MondEmbeddedHostFactory`
- the Mond dylib does contain `MondEmbeddedHostFactory`
- the core has no `LC_LOAD_DYLIB` dependency on `FilzaMondModern.dylib`
- the app executable has no eager dependency on `FilzaMondModern.dylib`
- Filza, 3105, ByeTunes, native Gestalt, SSH, and WebDAV remain in the universal core
- Mond 2.2 resources and the 3105 resource bundle are packaged in the same IPA
- the final IPA passes ZIP/package integrity checks before upload

The release pipeline publishes only `Filza-27.ipa` and its checksum after the exact-SHA universal verifier and full feature verifier are green.

## Compatibility note

The project does **not** claim a full jailbreak, kernel read/write, root shell, SPTM bypass, or writable system volume. Actual filesystem/container access depends on the iOS build and the access primitives available to the running app.

Mond's exploit support remains version-specific. The universal packaging only solves application/runtime compatibility across OS versions; it does not make Mond's exploit backend applicable to unsupported iOS builds.
