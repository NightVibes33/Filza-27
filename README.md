# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork for modern iOS that combines Filza with app/container management, ByeTunes music tools, Mond 2.2, WebDAV, SSH, and the 3105 patch workspace in one project.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### Current verified IPA — `filza-27-142`

### [Download `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/download/filza-27-142/Filza-27.ipa)

- Verified release: [`filza-27-142`](https://github.com/NightVibes33/Filza-27/releases/tag/filza-27-142)
- Exact build commit: `066390b6414d4e930750b319ff83ee177fa68272`
- SHA-256: `340ff70dd89571a9b99d51d8a48fba365e713cffc8ce11b32a50bb56a01e83d7`
- Checksum file: [`Filza-27-SHA256.txt`](https://github.com/NightVibes33/Filza-27/releases/download/filza-27-142/Filza-27-SHA256.txt)
- Rolling latest-green link: [`releases/latest/download/Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

Every public release is produced from **exact-SHA green GitHub Actions builds on `main`**. The release pipeline now verifies both the modern IPA and the iOS 16 compatibility IPA before publishing either one. `main` may temporarily move ahead of the latest release while a new build is being verified; the versioned download above intentionally stays pinned to the last published green IPA.

> **This is not a full jailbreak.** FilzaSlop exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## What's new — Mond 2.2 + iOS 16 support

The current source tree upgrades the full modern build to pinned **Mond 2.2** and adds a separately verified **iOS 16.1+ compatibility IPA**.

- Mond pinned to `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- Full Mond 2.2 navigation and shared `AppState` lifecycle integrated.
- New Mond 2.2 **CacheExtra Fields** editor included.
- New **Persist after reboot** and **Ignore exploit failure** settings included.
- **MobileGestalt**, **PosterBoard / Tendies**, and **HouseArrest / Santander** routes retained.
- **Run Exploit** and **Generate Token** retain the upstream Mond flow.
- Current MobileGestalt persistence and iOS 27 region-key behavior from the pinned upstream revision are included.
- 3105 keeps its broader existing app-enumeration path instead of replacing it with the narrower paired-device app scan.
- 3105 and ByeTunes share the same persisted pairing file and device tunnel state.
- 3105 upgrades app rows with rendered **SpringBoardServices** icons when the shared paired connection is available.
- Existing LaunchServices icons remain the immediate fallback, so app rows do not have to wait for the paired icon service.
- Enhanced icon requests use a small persistent worker pool, request deduplication, caching, and reconnect/retry behavior instead of reconnecting SpringBoardServices once per row.
- The untouched upstream Mond app source is preserved under `ThirdParty/mond-current/Upstream` for provenance.
- The compiled copy receives mechanical module/symbol namespacing plus explicit embedded-host adapters for Mond's `AccentColor`, `com.roooot.mond` preferences domain, app identity/resources, and shared environment state. These adapters are applied only to the generated embedded copy; the preserved upstream snapshot is not rewritten.
- A source-completeness gate compares the pinned functional Swift tree against the compiled Mond source list and fails the build if a future pin would silently omit a new upstream file.
- Sandbox SPI ABI forwarding is handled by `MondSandboxSPICompat.c` without rewriting Mond's preserved upstream source.
- The modern arm64 build is packaged with `MinimumOSVersion = 17.0`.
- The compatibility build is compiled and packaged with `MinimumOSVersion = 16.1` and intentionally excludes Mond's iOS 27-specific payload while keeping Filza, 3105, ByeTunes, SSH, WebDAV, and the native Gestalt Manager.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog that is automatically included in GitHub Releases.

## Included features

| Feature | Modern IPA | iOS 16.1+ IPA |
| --- | --- | --- |
| Filza file browser | ✅ | ✅ |
| Apps Manager | ✅ 3105 1.0.1 integrated | ✅ 3105 1.0.1 integrated |
| Shared device pairing | ✅ | ✅ |
| Enhanced app icons | ✅ SpringBoardServices when paired, LaunchServices fallback | ✅ where supported |
| `.3105` Patch Workspace v2 | ✅ | ✅ |
| 3105 IPA repackaging | ✅ | ✅ |
| Music Library / ByeTunes | ✅ | ✅ |
| YouTube metadata provider | ✅ | ✅ |
| Mond | ✅ Full pinned Mond 2.2 integration | ❌ intentionally excluded |
| MobileGestalt editor | ✅ Mond 2.2 | ✅ native Gestalt Manager |
| PosterBoard / Tendies | ✅ | ❌ Mond-only |
| HouseArrest / Santander | ✅ | ❌ Mond-only |
| WebDAV server | ✅ | ✅ |
| SSH server | ✅ | ✅ |
| Home Screen quick actions | ✅ | ✅ |
| Full jailbreak / writable system volume | ❌ Not claimed | ❌ Not claimed |

## Compatibility

The full modern IPA has a minimum deployment target of **iOS 17.0**. A second compatibility IPA has a minimum deployment target of **iOS 16.1**.

For iOS 27, the useful `bad_query` behavior is associated with beta 1–4. Do not assume the same access on beta 5 or newer. Exact access can vary by device and build, so FilzaSlop validates real file/directory access instead of treating a returned handle as automatic success.

The iOS 16 compatibility build does not claim that Mond's current iOS 27 access backend works on older systems. Gestalt actions use the native Gestalt Manager instead.

## Install

1. Download the current verified release from [`releases/latest`](https://github.com/NightVibes33/Filza-27/releases/latest).
2. Choose `Filza-27.ipa` for the full modern/Mond build, or `Filza-27-iOS16.ipa` when the release includes the iOS 16 compatibility build.
3. Sideload it with your preferred signing method.
4. Keep the base app identity when your signer allows it:

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

It includes application search, icon and disk-size recovery where available, container browsing, per-tab navigation, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, IPA repackaging support, and Patch Workspace handoff.

The Filza integration intentionally preserves 3105's broader application discovery. Pairing is used as an **optional icon-quality backend**, not as a replacement for enumeration: when the shared ByeTunes/Filza device connection is ready, 3105 requests the rendered icon for each bundle ID from SpringBoardServices and replaces the already-visible LaunchServices icon. If pairing, LocalDevVPN, or SpringBoardServices is unavailable, the existing icon remains in place.

### Patches

The embedded **3105 Patch Workspace v2** supports portable `.3105` projects, schema-v2 workspaces, legacy v1 decoding, bundle-ID targets, directory targets, import/export, backups, receipts, transaction journals, and restore flows.

### Music Library / ByeTunes

ByeTunes is embedded directly into FilzaSlop and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The current build also restores the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider while retaining the current ByeTunes integration. Required JavaScript solver resources are packaged inside the IPA.

ByeTunes owns the canonical pairing/device connection used by paired features. 3105 consumes that same persisted pairing state instead of maintaining a separate pairing database, so a valid connection established by one embedded feature can be reused by the other.

### Mond 2.2 / Gestalt Editor

Mond is staged from the exact pinned upstream revision, then its generated compiled copy is adapted only where embedding inside Filza changes the standalone app environment. The modern IPA supplies Mond's accent color, isolated preferences domain, dedicated resource bundle, and shared environment bindings so SwiftUI controls and Settings identity do not accidentally inherit Filza's app target.

Available modern routes include:

- MobileGestalt
- CacheExtra Fields
- PosterBoard / Tendies
- HouseArrest / Santander
- Settings / exploit controls

The exposed Mond access methods include:

- `bad_query`
- `cmg`

The MobileGestalt cache used by the editor is:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

The editor includes newer iOS 27 capability mappings alongside the existing Dynamic Island, Always-On Display, Camera Control, Action Button, Stage Manager, Apple Intelligence eligibility, internal-feature, and related controls.

On iOS 16, Gestalt actions are routed to the native Gestalt Manager instead of embedding Mond's newer payload.

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

The modern installable IPA workflow is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```

The universal/iOS 16 verification workflow is:

```text
.github/workflows/verify-ios16-support.yml
```

CI independently builds the full Mond 2.2 arm64 graph and the iOS 16.1 compatibility graph. The Mond verifier checks the complete pinned functional source graph, including the current MobileGestalt sources, and the iOS 16 verifier checks that Mond host symbols are absent while 3105, ByeTunes, and native Gestalt symbols remain present.

After both exact-SHA verifiers succeed, the release workflow:

```text
.github/workflows/publish-green-ipa-release.yml
```

waits for both verifier runs at the **same commit SHA**, downloads those exact artifacts, validates their IPA structure and minimum OS versions, calculates SHA-256, and publishes:

```text
Filza-27.ipa
Filza-27-SHA256.txt
Filza-27-iOS16.ipa
Filza-27-iOS16-SHA256.txt
```

The release body is generated from [`RELEASE_NOTES.md`](RELEASE_NOTES.md) plus the exact workflow runs and commit SHA used for the IPAs.

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
