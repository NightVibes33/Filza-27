# Filza 27 — Mond 2.1 Update

This release promotes the current verified FilzaSlop production tree with the full **Mond 2.1** integration and the existing Filza, 3105, ByeTunes, WebDAV, and SSH feature set packaged into one IPA.

## Highlights

### Mond 2.1

- Updated the embedded Mond integration to exact upstream Mond 2.1 source pinned at `500d76082f0ca021ddd591c05d129ebbc26c20df`.
- Preserved the complete upstream source tree under `ThirdParty/mond-current/Upstream` for provenance.
- Integrated Mond's shared `AppState` lifecycle and normal 2.1 navigation.
- Included MobileGestalt, PosterBoard / Tendies, and HouseArrest / Santander.
- Retained the upstream **Run Exploit** and **Generate Token** flow.
- Retained Mond 2.1 CacheExtra / safe MobileGestalt offset fixes.
- Retained the Mond 2.1 CMG grant-state fix.
- Removed dependence on the older Filza-only Mond behavior patches from the staging path.
- Added only the mechanical module/symbol namespacing needed to embed Mond alongside Filza's existing runtime.
- Added a Sandbox SPI ABI compatibility bridge that forwards to the same system sandbox symbols used by upstream Mond.

### Build and verification

- Verified the complete Mond 2.1 arm64 target compile/link path.
- Kept the ChOma arm64 PatchFinder implementation in the target to satisfy the required `pfsec_arm64_*` symbols.
- Added a compiler-only SwiftUI solver allowance for large embedded views without changing runtime behavior.
- Split ByeTunes' large `ManageBackupsView` expression mechanically to keep the current UI/actions while avoiding Swift constraint-solver failures.
- The release pipeline now publishes only an IPA produced by the green verifier at the exact same `main` commit SHA.
- Every release includes `Filza-27-SHA256.txt` alongside `Filza-27.ipa`.

### Existing integrated features

- Filza file browser based on the anchored Filza 4.11 package path.
- 3105 1.0.1 Apps Manager and Patch Workspace v2.
- ByeTunes music-management interface and persistent queue/backup tooling.
- Restored YouTubeKit metadata path and bundled solver resources.
- In-process WebDAV server.
- In-process libssh SSH server.
- Home Screen quick actions for Apps Manager, Music Library, Gestalt Editor, and Patches.

## Compatibility note

The project does **not** claim a full jailbreak, kernel read/write, root shell, SPTM bypass, or writable system volume. Actual filesystem/container access depends on the iOS build and the access primitives available to the running app.

For iOS 27, `bad_query` behavior is associated with beta 1–4 and should not be assumed to work on beta 5 or newer.
