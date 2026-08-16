# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork for modern iOS that combines Filza with app/container management, ByeTunes music tools, Mond 2.1, WebDAV, SSH, and the 3105 patch workspace in one IPA.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### [Download the latest verified `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

Every public `Filza-27.ipa` release is produced from an **exact-SHA green GitHub Actions build on `main`**. The release also includes `Filza-27-SHA256.txt` so the IPA can be verified after download.

> **This is not a full jailbreak.** FilzaSlop exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## What's new — Mond 2.1 update

The current production tree embeds the **full pinned Mond 2.1 functional source surface** instead of the older Filza-specific Mond implementation.

- Mond pinned to `rooootdev/mond@500d76082f0ca021ddd591c05d129ebbc26c20df`.
- Full Mond 2.1 navigation and shared `AppState` lifecycle integrated.
- **MobileGestalt**, **PosterBoard / Tendies**, and **HouseArrest / Santander** routes included.
- **Run Exploit** and **Generate Token** use the upstream Mond 2.1 flow.
- Mond 2.1 MobileGestalt CacheExtra / safe-offset fixes retained.
- Mond 2.1 CMG grant-state fix retained.
- The untouched upstream app source is preserved under `ThirdParty/mond-current/Upstream` for provenance.
- The compiled copy receives mechanical module/symbol namespacing plus explicit embedded-host adapters for Mond's pinned `AccentColor`, `com.roooot.mond` preferences domain, and Mond app identity/resources. These adapters are applied only to the generated embedded copy; the preserved upstream snapshot is not rewritten.
- A source-completeness gate compares the pinned functional Swift tree against the compiled Mond source list and fails the build if a future pin would silently omit a new upstream file.
- Sandbox SPI ABI forwarding is handled by `MondSandboxSPICompat.c` without rewriting Mond's preserved upstream source.
- The complete arm64 Mond integration and Filza 4.11 IPA packaging are verified in GitHub Actions.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog that is automatically included in GitHub Releases.

## Included features

| Feature | Status |
| --- | --- |
| Verified release IPA | ✅ Exact-SHA green build required |
| Filza file browser | ✅ Included |
| Apps Manager | ✅ 3105 1.0.1 integrated |
| `.3105` Patch Workspace v2 | ✅ Integrated |
| Music Library / ByeTunes | ✅ Integrated |
| YouTube metadata provider | ✅ Restored and bundled |
| Mond | ✅ Full pinned Mond 2.1 functional integration |
| MobileGestalt editor | ✅ Included through Mond |
| PosterBoard / Tendies | ✅ Included through Mond |
| HouseArrest / Santander | ✅ Included through Mond |
| WebDAV server | ✅ In-process server |
| SSH server | ✅ In-process libssh server |
| Home Screen quick actions | ✅ Apps Manager, Music Library, Gestalt Editor, Patches |
| Full jailbreak / writable system volume | ❌ Not claimed |

## Compatibility

This fork targets the modern iOS behavior used by its bundled container-access methods, including iOS 18, iOS 26, and early iOS 27 builds.

For iOS 27, the useful `bad_query` behavior is associated with beta 1–4. Do not assume the same access on beta 5 or newer. Exact access can vary by device and build, so FilzaSlop validates real file/directory access instead of treating a returned handle as automatic success.

## Install

1. Download the latest verified [`Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa).
2. Sideload it with your preferred signing method.
3. Keep the base app identity when your signer allows it:

```text
com.apple.mobile.MobileHouseArrest
```

Changing that bundle identifier can break MobileHouseArrest-dependent behavior.

## Main tools

### Apps Manager / 3105

Apps Manager embeds **3105 1.0.1**, pinned to:

```text
NightVibes33/3105@90ab4dd35823d58de10e6b8b78236e0e7e1ad32b
```

It includes application search, icon and disk-size recovery where available, container browsing, per-tab navigation, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, and Patch Workspace handoff.

### Patches

The embedded **3105 Patch Workspace v2** supports portable `.3105` projects, schema-v2 workspaces, legacy v1 decoding, bundle-ID targets, directory targets, import/export, backups, receipts, transaction journals, and restore flows.

### Music Library / ByeTunes

ByeTunes is embedded directly into FilzaSlop and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The current build also restores the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider while retaining the current ByeTunes integration. Required JavaScript solver resources are packaged inside the IPA.

### Mond 2.1 / Gestalt Editor

Mond is staged from the exact pinned upstream commit, then its generated compiled copy is adapted only where embedding inside Filza changes the standalone app environment. The IPA supplies Mond's accent color, isolated preferences domain, and a dedicated Mond resource bundle so SwiftUI controls and Settings identity do not accidentally inherit Filza's app target.

Available routes include:

- MobileGestalt
- PosterBoard / Tendies
- HouseArrest / Santander
- Settings / exploit controls

The two exposed access methods are:

- `bad_query`
- `cmg`

The MobileGestalt cache used by the editor is:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

The editor includes newer iOS 27 capability mappings alongside the existing Dynamic Island, Always-On Display, Camera Control, Action Button, Stage Manager, Apple Intelligence eligibility, internal-feature, and related controls.

## Logs

Runtime logs are stored under:

```text
Documents/FilzaSlop Logs/
```

Useful files include:

```text
Runtime.log
WebDAVStatus.txt
SSHStatus.txt
ByeTunesEmbedStage.txt
```

## Verification and builds

The installable IPA workflow is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```

It verifies pinned dependencies, checks the Mond functional-source graph for completeness, stages Mond app-target parity resources, stages 3105 / ByeTunes sources and resources, builds the arm64 runtime, packages the anchored Filza base IPA, verifies the package, and uploads the exact artifact.

After that succeeds, the release workflow:

```text
.github/workflows/publish-green-ipa-release.yml
```

waits for the verifier at the **same commit SHA**, downloads that exact artifact, validates it, calculates SHA-256, and publishes:

```text
Filza-27.ipa
Filza-27-SHA256.txt
```

The release body is generated from [`RELEASE_NOTES.md`](RELEASE_NOTES.md) plus the exact workflow run and commit SHA used for the IPA.

## Current limitations

- A green Actions build proves compilation, linking, packaging, and artifact verification; it cannot prove every private API behaves identically on every device/build.
- `/System/Library` can be readable while remaining on iOS's signed read-only system volume.
- Access to an App Group or data container does not imply access to the entire filesystem.
- Kernel read/write is not established by this project.
- No full jailbreak, root shell, SPTM bypass, or system-volume remount is claimed.
- WebDAV and SSH are app-hosted services and can be suspended in the background.

## Upstream projects and credits

FilzaSlop combines work from multiple open-source projects. Their upstream licenses and notices remain part of the repository.

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)
- [0xjohnnydev/MobileHouseArrest-PoC](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [forcequitOS/bad_query](https://github.com/forcequitOS/bad_query)
- [rooootdev/mond](https://github.com/rooootdev/mond)
- [YangJiiii/3105](https://github.com/YangJiiii/3105)
- [NightVibes33/3105](https://github.com/NightVibes33/3105)
- [EduAlexxis/ByeTunes](https://github.com/EduAlexxis/ByeTunes)
- [swisspol/GCDWebServer](https://github.com/swisspol/GCDWebServer)
- [libssh](https://www.libssh.org/)
- XPF and ChOma contributors
- CrazyMind90
- `SerStars/nugget-wallpapers`
- mightycooldude12

## Research note

This repository includes compatibility and filesystem-access research for modern iOS. Those experiments should be treated as research features, not as proof of unrestricted system access.
