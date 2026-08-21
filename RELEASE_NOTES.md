

## Download

- `Filza-27.ipa` — one universal arm64 IPA with `MinimumOSVersion = 16.1`.
- `Filza-27-SHA256.txt` — SHA-256 checksum for that IPA.


## Universal runtime model


- `Frameworks/FilzaApplySandboxExt.dylib` — Filza integration, 3105 1.1.1, ByeTunes, SSH, WebDAV, native Gestalt fallback, and runtime routing.

The core deliberately does **not** link Mond eagerly. Mond is lazy-loaded from the same IPA when requested. If the Mond host cannot load, Filza falls back to its native Gestalt Manager.


The embedded generated copy is derived from upstream `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`. The untouched upstream snapshot remains under `ThirdParty/mond-current/Upstream`.


- `Observation/@Observable` Tendies state -> Combine `ObservableObject/@Published`.
- Tendies VM ownership -> `@StateObject`.
- `.topBarTrailing` -> `.navigationBarTrailing`.

## 3105 1.1.1 update

The embedded Apps Manager/Patches workspace is pinned directly to official upstream:

`YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa`

The build stages the current 1.1.1 workspace source, metadata/localization, support-policy changes, Files/Patches behavior, and the updated backend units already represented by Filza's build graph. Filza-specific pairing/icon integration and direct Home / Apps Manager / Patches entry points are retained.

Because 3105 is embedded rather than process owner, standalone-global lifecycle/window hooks are not installed into Filza. In particular, the standalone process-wide `fork()` override and root-window attribution gesture are excluded so they cannot alter Filza, SSH, Mond, or ByeTunes behavior outside the 3105 view.

## Unified embedded-app UI

**3105 is now the canonical presentation style for all presented third-party tools.** 3105, Mond, and presented ByeTunes use the exact same `FilzaEmbeddedPanel.swift` source for:

- persistent top-left **Close** action;
- material header and divider;
- large `.pageSheet` presentation;
- visible grabber;
- consistent dismissal behavior.

The third-party apps retain their own internal views and features. **Filza's own file-browser/navigation UI is not restyled or replaced.**

The legacy ByeTunes child-controller route remains unwrapped only when Filza already owns the containing Music Library controller, preventing a modal shell from being nested inside another Filza-owned screen. The normal presented ByeTunes route uses the shared panel.


- Filza core file browser
- 3105 1.1.1 Apps Manager and Patch Workspace
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
- shared 3105-style presentation/exit shell for 3105, Mond, and presented ByeTunes

## Access/backend compatibility

UI/runtime compatibility and filesystem-access compatibility are separate.



For modern iOS 27 research builds, do not assume an access primitive works merely because the UI is available. Filza-27 validates actual filesystem/container access at runtime.

## Build and verification

The universal verifier builds both runtime layers from the same commit and packages them into one IPA. CI verifies:

- application `MinimumOSVersion = 16.1`
- core dylib Mach-O minimum OS = 16.1
- Mond dylib Mach-O minimum OS = 16.1
- iOS-17-only Tendies/Santander/CacheExtra SwiftUI forms are absent from the generated compatibility copy
- PosterBoard has the 59/61 runtime descriptor-store selector
- the core contains no `MondEmbeddedHostFactory`
- the Mond dylib does contain `MondEmbeddedHostFactory`
- the core has no eager `LC_LOAD_DYLIB` dependency on `FilzaMondModern.dylib`
- the app executable has no eager dependency on `FilzaMondModern.dylib`
- 3105 staging validates pinned upstream 1.1.1 metadata and embedding contracts
- Filza, 3105, ByeTunes, SSH, WebDAV, and routing symbols remain present
- Mond and 3105 resource bundles are packaged in the same IPA
- the final IPA passes ZIP/package integrity checks before upload

The release pipeline publishes only `Filza-27.ipa` and `Filza-27-SHA256.txt` after the exact-SHA universal and full-feature workflows are green.

## Compatibility note

This project does **not** claim a full jailbreak, unrestricted root filesystem, root shell, SPTM bypass, or writable system volume from the modern packaging work. A green CI build proves compilation, linking, deployment targets, resources, and packaging; private API and cross-container behavior still depends on the actual device/iOS build and must be validated on-device.
