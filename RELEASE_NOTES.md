# Filza 27 — Mond 2.1 Update

This release promotes the current verified FilzaSlop production tree with the pinned **Mond 2.1** functional integration and the existing Filza, 3105, ByeTunes, WebDAV, and SSH feature set packaged into one IPA.

## Highlights

### Mond 2.1

- Updated the embedded Mond integration to upstream Mond source pinned at `500d76082f0ca021ddd591c05d129ebbc26c20df`.
- Preserved the complete upstream `mond/` app source tree under `ThirdParty/mond-current/Upstream` for provenance.
- Integrated Mond's shared `AppState` lifecycle and normal navigation.
- Included MobileGestalt, PosterBoard / Tendies, and HouseArrest / Santander.
- Retained the upstream **Run Exploit** and **Generate Token** flow.
- Retained the pinned CacheExtra / safe MobileGestalt offset fixes.
- Retained the pinned CMG grant-state fix.
- Removed dependence on the older Filza-only Mond behavior patches from the staging path.
- Kept mechanical module/symbol namespacing in the generated compiled copy so Mond can coexist with Filza's existing runtime.
- Added explicit embedded-host parity for the standalone Mond app environment: the pinned `AccentColor`, a dedicated `com.roooot.mond` UserDefaults domain, and a dedicated Mond bundle identity/artwork resource.
- The app-target parity fix restores the upstream MobileGestalt action-button tint instead of allowing `Apply Tweaks`, `Revert Tweaks`, and `Respring` to render with an invalid inherited color inside Filza.
- Mond Settings now reads Mond's staged bundle identity/version/artwork rather than leaking Filza's `4.11` `Bundle.main` identity.
- Added a source-completeness gate that fails the build if the pinned Mond functional Swift tree and the compiled embedded source list ever diverge.
- Added a Sandbox SPI ABI compatibility bridge that forwards to the same system sandbox symbols used by upstream Mond.

### Build and verification

- Verifies the pinned upstream source markers before adaptation and verifies the generated embedded source separately after adaptation.
- Verifies every functional Mond Swift file at the pinned commit is represented in the generated compiled source graph, with `mond.swift` intentionally replaced by the Filza host lifecycle.
- Verifies the Mond embedded resource bundle is packaged into the final IPA with display name `mond`, version `2.0`, bundle identity `com.roooot.mond`, and pinned upstream artwork.
- Verified the complete Mond arm64 target compile/link path.
- Kept the ChOma arm64 PatchFinder implementation in the target to satisfy the required `pfsec_arm64_*` symbols.
- Added a compiler-only SwiftUI solver allowance for large embedded views without changing runtime behavior.
- Split ByeTunes' large `ManageBackupsView` expression mechanically to keep the current UI/actions while avoiding Swift constraint-solver failures.
- The release pipeline publishes only an IPA produced by the green verifier at the exact same `main` commit SHA.
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
