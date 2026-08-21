# Filza 27 — Modern iOS 17+ + Mond 2.2 + 3105 1.1.1

This release restores Filza-27 to a single integrated **iOS 17.0+** runtime and includes the latest selected FilzaSlop runtime updates.

## Download

- `Filza-27.ipa` — arm64 IPA with `MinimumOSVersion = 17.0`.
- `Filza-27-SHA256.txt` — SHA-256 checksum for the IPA.

## Modern runtime model

The app ships one runtime layer:

- `Frameworks/FilzaApplySandboxExt.dylib` — Filza integration, full Mond 2.2 host, 3105 1.1.1, ByeTunes, SSH/SFTP, WebDAV, Gestalt routing, and runtime hooks.

The former iOS 16 compatibility path is removed:

- no `MondModern` build target;
- no `Frameworks/FilzaMondModern.dylib`;
- no `scripts/prepare-ios16-compat.sh`;
- no `scripts/patch-mond-ios16-backport.sh`;
- no iOS 16-specific Mond runtime defaults/behavior;
- legacy iOS 16/universal workflows are disabled and do not build or publish artifacts.

The release packager forces `MinimumOSVersion = 17.0`, removes any stale split Mond dylib from the base IPA, and asserts that both conditions hold.

## FilzaSlop upstream updates

Selected post-fork FilzaSlop changes are included without replacing Filza-27's downstream integrations:

- LiveContainer compatibility using signed-code identity and guest-specific roots;
- Archive support and safer permanent-delete handling for MCM-backed items;
- generated-file deletion tracking so intentionally deleted generated files remain absent;
- release IPA `CFBundleURLTypes` stripping with a hard packaging assertion.

The exact iOS 18.5 kernel path and constructor gate remain unchanged by this sync.

## Mond 2.2

The embedded Mond source is pinned to:

`rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`

Mond 2.2 is compiled directly into the main Filza core and retains the current embedded host environment, defaults domain, resources, namespace, and shared state adapters.

Included routes include:

- MobileGestalt
- CacheExtra Fields
- PosterBoard / Tendies
- HouseArrest / Santander
- Settings / Run Exploit / Generate Token
- Persist after reboot / Ignore exploit failure

Exploit-backed access remains OS/build-specific; UI availability is not proof of unrestricted filesystem access.

## 3105 1.1.1

The embedded Apps Manager/Patches workspace is pinned to:

`YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa`

Filza retains the current 1.1.1 Files/Patches behavior, IPA repackaging, pairing/icon integration, and embedded-host isolation. Standalone-global lifecycle/window hooks are not installed into the Filza host.

## Unified embedded-app UI

3105, Mond, and presented ByeTunes use the same `FilzaEmbeddedPanel.swift` presentation shell for the Close action, material header/divider, large page sheet, grabber, and dismissal behavior.

Their internal views remain independent and Filza's file-browser/navigation UI is not replaced.

## ByeTunes, WebDAV, and SSH/SFTP

The current downstream integrations remain present:

- ByeTunes / Music Library
- multi-source metadata routing
- YouTube metadata provider and packaged JS solver resources
- shared device pairing used by ByeTunes and 3105
- app-hosted WebDAV server
- embedded libssh SSH/SFTP server
- local-network and Bonjour metadata required by those services

## Build and verification

The production verifier is:

`.github/workflows/verify-upstream-byetunes-ssh.yml`

It builds the full integrated runtime at `TARGET=iphone:clang:latest:17.0`, verifies Mond/3105/ByeTunes/SSH/WebDAV symbols and resources, packages a modern unsigned IPA, asserts that `FilzaMondModern.dylib` is absent, asserts `MinimumOSVersion = 17.0`, strips `CFBundleURLTypes`, and uploads the verified artifact.

The 3105/shared-presentation source contract is verified separately by:

`.github/workflows/verify-3105-shared-ui.yml`

The release pipeline publishes only `Filza-27.ipa` and `Filza-27-SHA256.txt` after the exact-SHA modern full-feature workflow succeeds.

## Compatibility note

This project does **not** claim a full jailbreak, unrestricted root filesystem, root shell, SPTM bypass, or writable system volume. A green CI build proves compilation, linking, deployment target, resources, and packaging; private API and cross-container behavior still depends on the actual device/iOS build and must be validated on-device.
