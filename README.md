# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork combining Filza with app/container management, ByeTunes, Mond 2.2, WebDAV, SSH, and the 3105 patch workspace.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### [Download the latest `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

- One IPA for **iOS 16.1+**.
- Checksum: [`Filza-27-SHA256.txt`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27-SHA256.txt)
- Every public release is produced from an exact-SHA green GitHub Actions build on `main`.

The release pipeline publishes **one IPA**, not separate modern and iOS 16 packages.

> **This is not a full jailbreak.** FilzaSlop exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## Universal iOS 16.1+ architecture

`Filza-27.ipa` has `MinimumOSVersion = 16.1` and contains two runtime layers in the same app bundle:

- `Frameworks/FilzaApplySandboxExt.dylib` — iOS **16.1+** core containing Filza integration, 3105, ByeTunes, SSH, WebDAV, native Gestalt, and runtime routing.
- `Frameworks/FilzaMondModern.dylib` — iOS **17.0+** Mond 2.2 module bundled inside the same IPA.

The core does not link the Mond module eagerly. On iOS 17+ it loads `FilzaMondModern.dylib` from the app's Frameworks directory only when Mond is requested. On iOS 16, that newer Mach-O is never loaded and Gestalt actions use the native Gestalt Manager.

This keeps one installable IPA across the supported OS range without changing Mond's real deployment requirement.

## What's new — Mond 2.2 + one universal IPA

- Mond pinned to `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- Full Mond 2.2 navigation and shared `AppState` lifecycle retained on supported newer systems.
- **CacheExtra Fields** editor included.
- **Persist after reboot** and **Ignore exploit failure** settings included.
- **MobileGestalt**, **PosterBoard / Tendies**, and **HouseArrest / Santander** routes retained.
- **Run Exploit** and **Generate Token** retain the upstream Mond flow.
- Current MobileGestalt persistence and iOS 27 region-key behavior from the pinned upstream revision are included.
- 3105 and ByeTunes keep their shared persisted pairing/device connection.
- 3105 keeps its broader app enumeration and SpringBoardServices icon upgrade path with LaunchServices fallback.
- The untouched upstream Mond source snapshot remains under `ThirdParty/mond-current/Upstream`.
- The generated embedded Mond copy retains its explicit AccentColor, `com.roooot.mond` defaults domain, resource-bundle, namespace, and shared-state adapters.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog.

## Included features

| Feature | iOS 16.1 | iOS 17+ / supported newer systems |
| --- | --- | --- |
| Filza file browser | ✅ | ✅ |
| Apps Manager | ✅ 3105 1.0.1 | ✅ 3105 1.0.1 |
| Shared device pairing | ✅ | ✅ |
| Enhanced app icons | ✅ where supported | ✅ SpringBoardServices with LaunchServices fallback |
| `.3105` Patch Workspace v2 | ✅ | ✅ |
| 3105 IPA repackaging | ✅ | ✅ |
| Music Library / ByeTunes | ✅ | ✅ |
| YouTube metadata provider | ✅ | ✅ |
| MobileGestalt editor | ✅ native Gestalt Manager | ✅ Mond 2.2 where applicable |
| Mond 2.2 UI/runtime | Not loaded | ✅ lazy-loaded module |
| CacheExtra Fields | — | ✅ |
| PosterBoard / Tendies | — | ✅ Mond route |
| HouseArrest / Santander | — | ✅ Mond route |
| WebDAV server | ✅ | ✅ |
| SSH server | ✅ | ✅ |
| Home Screen quick actions | ✅ | ✅ |
| Full jailbreak / writable system volume | ❌ Not claimed | ❌ Not claimed |

## Compatibility

The IPA itself supports **iOS 16.1 and newer**.

Mond remains version-specific. Bundling its iOS-17+ runtime in the universal IPA does not make its exploit backend valid on every iOS version. On iOS 16, the newer module is not loaded.

For iOS 27, the useful `bad_query` behavior is associated with beta 1–4. Do not assume the same access on beta 5 or newer. Exact access varies by device/build, so FilzaSlop validates actual filesystem/container access instead of treating a returned handle as automatic success.

## Install

1. Download [`Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa).
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

It includes application search, icon and disk-size recovery where available, container browsing, per-tab navigation, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, IPA repackaging support, and Patch Workspace handoff.

Pairing remains an optional icon-quality backend rather than a replacement for app enumeration. When the shared ByeTunes/Filza connection is ready, 3105 can request rendered SpringBoardServices icons; otherwise existing LaunchServices icons remain available.

### Patches

The embedded **3105 Patch Workspace v2** supports portable `.3105` projects, schema-v2 workspaces, legacy v1 decoding, bundle-ID targets, directory targets, import/export, backups, receipts, transaction journals, and restore flows.

### Music Library / ByeTunes

ByeTunes is embedded directly into FilzaSlop and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The current integration also restores the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider while retaining current ByeTunes behavior. Required JavaScript solver resources are packaged inside the IPA.

ByeTunes owns the canonical pairing/device connection used by paired features, and 3105 consumes that same persisted state.

### Mond 2.2 / Gestalt Editor

Mond is staged from the exact pinned upstream revision. Only the generated embedded copy receives the host adaptations required to run inside Filza; the upstream snapshot remains unchanged.

Available Mond routes include:

- MobileGestalt
- CacheExtra Fields
- PosterBoard / Tendies
- HouseArrest / Santander
- Settings / exploit controls

Exposed Mond access methods include:

- `bad_query`
- `cmg`

The MobileGestalt cache used by the editor is:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

On iOS 16, Gestalt actions route to the native Gestalt Manager instead of loading the modern Mond module.

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

The full feature verifier is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```

The one-IPA universal verifier is:

```text
.github/workflows/verify-single-universal-ipa.yml
```

It builds the iOS 17+ Mond module first, then builds the iOS 16.1-compatible core, packages both into the **same IPA**, and verifies that the core/app do not eagerly link the newer module.

CI verifies the core and optional Mond Mach-O deployment targets independently, checks expected symbols/resources, and validates the final IPA structure.

After the exact-SHA universal and full-feature verifiers succeed, the release workflow:

```text
.github/workflows/publish-green-ipa-release.yml
```

publishes only:

```text
Filza-27.ipa
Filza-27-SHA256.txt
```

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

This repository includes compatibility and filesystem-access research for modern iOS. Those experiments should be treated as research features, not proof of unrestricted system access.
