# Filza 27 — Universal iOS 16.1+ + Mond 2.2

This release ships Filza, 3105, ByeTunes, WebDAV, SSH, native Gestalt fallback, and the full pinned Mond 2.2 interface in **one IPA** for **iOS 16.1+**.

## Download

- `Filza-27.ipa` — one universal arm64 IPA with `MinimumOSVersion = 16.1`.
- `Filza-27-SHA256.txt` — SHA-256 checksum for that IPA.

There is no separate iOS 16 IPA.

## Universal runtime model

The IPA contains two runtime layers, both compiled for **iOS 16.1+**:

- `Frameworks/FilzaApplySandboxExt.dylib` — Filza integration, 3105, ByeTunes, SSH, WebDAV, native Gestalt fallback, and runtime routing.
- `Frameworks/FilzaMondModern.dylib` — the full pinned **Mond 2.2** interface/runtime, backported to iOS 16.1-compatible SwiftUI/Combine APIs.

The core deliberately does **not** link Mond eagerly. Mond is lazy-loaded from the same IPA when requested. If the Mond host cannot load, Filza falls back to its native Gestalt Manager.

## Mond 2.2 iOS 16 backport

The embedded generated copy is derived from upstream `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`. The untouched upstream snapshot remains under `ThirdParty/mond-current/Upstream`.

The compatibility stage keeps Mond's feature flow while replacing iOS-17-only presentation/state APIs with iOS-16 equivalents:

- `Observation/@Observable` Tendies state -> Combine `ObservableObject/@Published`.
- Tendies VM ownership -> `@StateObject`.
- `ContentUnavailableView` states -> equivalent iOS-16 `VStack`/`Label`/`Text` states.
- `.topBarTrailing` -> `.navigationBarTrailing`.
- iOS-17 two-value `onChange` closures -> iOS-16 single-value overloads.
- PosterBoard descriptor store is selected at runtime: **59 on iOS 16**, **61 on iOS 17+**.

## Included on iOS 16.1+

- Filza core file browser
- 3105 Apps Manager and Patch Workspace
- 3105 IPA repackaging
- ByeTunes / Music Library
- YouTube metadata provider and packaged JS solver resources
- SSH server
- WebDAV server
- Home Screen quick actions
- Mond 2.2 root interface
- MobileGestalt editor
- CacheExtra Fields editor
- PosterBoard
- Tendies browser/download/import flow
- HouseArrest / Santander browser
- Settings / Run Exploit / Generate Token UI
- Persist after reboot / Ignore exploit failure settings
- native Gestalt Manager fallback

## Access/backend compatibility

UI/runtime compatibility and filesystem-access compatibility are separate.

Mond now builds and loads from iOS 16.1 upward, but exploit-backed grants such as `bad_query` and `cmg` remain **OS/build-specific**. A feature that needs write access to another process/container still requires an access primitive that actually works on that device and iOS build.

On iOS 16, PosterBoard uses the correct generation-59 descriptor location. Tendies/PosterBoard can browse/import/process their data through the Mond UI, while applying changes still depends on writable access to the required PosterBoard container.

For modern iOS 27 research builds, do not assume an access primitive works merely because the UI is available. Filza-27 validates actual filesystem/container access at runtime.

## Build and verification

The universal verifier builds both runtime layers from the same commit and packages them into one IPA. CI verifies:

- application `MinimumOSVersion = 16.1`
- core dylib Mach-O minimum OS = 16.1
- Mond dylib Mach-O minimum OS = 16.1
- complete Mond 2.2 source graph compiles under the iOS 16.1 deployment target
- iOS-17-only Tendies/Santander/CacheExtra SwiftUI forms are absent from the generated compatibility copy
- PosterBoard has the 59/61 runtime descriptor-store selector
- the core contains no `MondEmbeddedHostFactory`
- the Mond dylib does contain `MondEmbeddedHostFactory`
- the core has no eager `LC_LOAD_DYLIB` dependency on `FilzaMondModern.dylib`
- the app executable has no eager dependency on `FilzaMondModern.dylib`
- Filza, 3105, ByeTunes, SSH, WebDAV, and routing symbols remain present
- Mond and 3105 resource bundles are packaged in the same IPA
- the final IPA passes ZIP/package integrity checks before upload

The release pipeline publishes only `Filza-27.ipa` and `Filza-27-SHA256.txt` after the exact-SHA universal and full-feature workflows are green.

## Compatibility note

This project does **not** claim a full jailbreak, kernel read/write, root shell, SPTM bypass, or writable system volume. A green CI build proves compilation, linking, deployment targets, resources, and packaging; private API and cross-container behavior still depends on the actual device/iOS build and must be validated on-device.
