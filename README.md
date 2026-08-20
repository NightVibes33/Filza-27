# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork combining Filza with app/container management, ByeTunes, Mond 2.2, WebDAV, SSH, and the 3105 patch workspace.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### [Download the latest `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

- One IPA for **iOS 16.1+**.
- Checksum: [`Filza-27-SHA256.txt`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27-SHA256.txt)
- Every public release is produced from an exact-SHA green GitHub Actions build on `main`.

The release pipeline publishes **one IPA**, not separate modern and iOS 16 packages.

> **This is not a full jailbreak.** Filza-27 exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## Universal iOS 16.1+ architecture

`Filza-27.ipa` has `MinimumOSVersion = 16.1` and contains two runtime layers in the same app bundle:

- `Frameworks/FilzaApplySandboxExt.dylib` — iOS **16.1+** core containing Filza integration, 3105, ByeTunes, SSH, WebDAV, native Gestalt fallback, and runtime routing.
- `Frameworks/FilzaMondModern.dylib` — full pinned **Mond 2.2**, backported and compiled for iOS **16.1+**.

The core does not link the Mond module eagerly. When Mond is requested, the bridge lazy-loads `FilzaMondModern.dylib` from the app's Frameworks directory. If the Mond host cannot load, Filza falls back to the native Gestalt Manager.

The Mond compatibility stage preserves the upstream feature flow while replacing iOS-17-only SwiftUI/state conveniences with iOS-16-compatible equivalents. PosterBoard selects descriptor store **59 on iOS 16** and **61 on iOS 17+**.

## What's new — full Mond 2.2 on iOS 16.1+

- Mond pinned to `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- Full Mond 2.2 navigation and shared `AppState` lifecycle available from iOS 16.1+.
- **CacheExtra Fields** editor included.
- **Persist after reboot** and **Ignore exploit failure** settings included.
- **MobileGestalt**, **PosterBoard / Tendies**, and **HouseArrest / Santander** routes included.
- **Run Exploit** and **Generate Token** retain the upstream Mond flow.
- Tendies `Observation/@Observable` state is backported to Combine `ObservableObject/@Published`.
- iOS-17-only empty-state, toolbar-placement, and two-value `onChange` APIs are replaced with iOS-16 equivalents in the generated embedded copy.
- PosterBoard descriptor-store routing is runtime-correct for iOS 16 vs iOS 17+.
- Current MobileGestalt persistence and iOS 27 region-key behavior from the pinned upstream revision are retained.
- 3105 and ByeTunes keep their shared persisted pairing/device connection.
- 3105 keeps broader app enumeration and SpringBoardServices icon upgrade with LaunchServices fallback.
- The untouched upstream Mond source snapshot remains under `ThirdParty/mond-current/Upstream`.
- The generated embedded Mond copy retains its explicit AccentColor, `com.roooot.mond` defaults domain, resource bundle, namespace, and shared-state adapters.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog.

## Included features

| Feature | iOS 16.1+ | Notes |
| --- | --- | --- |
| Filza file browser | ✅ | Actual filesystem visibility still follows sandbox/access state |
| Apps Manager | ✅ 3105 1.0.1 | App/container details depend on available APIs/permissions |
| Shared device pairing | ✅ | Used by ByeTunes/3105 paired features |
| Enhanced app icons | ✅ where supported | SpringBoardServices with LaunchServices fallback |
| `.3105` Patch Workspace v2 | ✅ | Portable projects, backup/restore, receipts/journals |
| 3105 IPA repackaging | ✅ | Included in the single IPA |
| Music Library / ByeTunes | ✅ | Full embedded ByeTunes integration |
| YouTube metadata provider | ✅ | Required solver resources packaged |
| Mond 2.2 UI/runtime | ✅ | Mond dylib itself has minOS 16.1 |
| MobileGestalt editor | ✅ | Mond route; native Gestalt remains fallback |
| CacheExtra Fields | ✅ | iOS-16-compatible UI backport |
| PosterBoard | ✅ | Store 59 on iOS16, 61 on iOS17+ |
| Tendies browser/download/import | ✅ | Applying requires writable PosterBoard access |
| HouseArrest / Santander | ✅ | Direct access first; exploit-backed grants remain version-specific |
| WebDAV server | ✅ | App-hosted service |
| SSH server | ✅ | App-hosted service |
| Home Screen quick actions | ✅ | Mond/Gestalt routing preserved on iOS16 |
| Full jailbreak / writable system volume | ❌ Not claimed | Outside this project's proven capabilities |

## Compatibility

The **application, core runtime, and Mond 2.2 runtime all build with a minimum deployment target of iOS 16.1**.

That does not mean every access primitive works on every OS version. Mond's `bad_query`, `cmg`, private APIs, and cross-container write paths remain OS/build-specific. Filza-27 keeps the UI/runtime portable while validating what access is actually available on the running device.

For iOS 16, the PosterBoard format/path compatibility is handled by using descriptor store `59`. For iOS 17 and newer, Mond uses store `61`.

For iOS 27 research builds, useful `bad_query` behavior is associated with specific builds; do not infer unrestricted access merely because Mond loads. Exact access varies by device/build.

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

Pairing remains an optional icon-quality backend rather than a replacement for app enumeration. When the shared ByeTunes/Filza connection is ready, 3105 can request rendered SpringBoardServices icons; otherwise LaunchServices icons remain available.

### Patches

The embedded **3105 Patch Workspace v2** supports portable `.3105` projects, schema-v2 workspaces, legacy v1 decoding, bundle-ID targets, directory targets, import/export, backups, receipts, transaction journals, and restore flows.

### Music Library / ByeTunes

ByeTunes is embedded directly into Filza-27 and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The integration restores the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider while retaining current ByeTunes behavior. Required JavaScript solver resources are packaged inside the IPA.

ByeTunes owns the canonical pairing/device connection used by paired features, and 3105 consumes that same persisted state.

### Mond 2.2 / Gestalt / PosterBoard

Mond is staged from the exact pinned upstream revision. Only the generated embedded copy receives the host and iOS-16 compatibility adaptations required to run inside Filza; the upstream snapshot remains unchanged.

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

On iOS 16.1+, the Mond host is attempted normally. Native Gestalt is used only if the Mond host cannot be loaded.

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

It builds Mond 2.2 with deployment target **16.1**, builds the iOS 16.1-compatible core, packages both into the **same IPA**, and verifies that the app/core do not eagerly link the Mond module.

CI verifies both Mach-O deployment targets, the iOS-16 generated-source backport, expected symbols/resources, PosterBoard 59/61 routing, and final IPA structure.

The supplemental iOS 16 workflow verifies the core graph as a diagnostic build only; it no longer publishes a second IPA.

After the exact-SHA universal and full-feature verifiers succeed, the release workflow publishes only:

```text
Filza-27.ipa
Filza-27-SHA256.txt
```

## Current limitations

- A green Actions build proves compilation, linking, deployment targets, packaging, and artifact verification; it cannot prove every private API behaves identically on every device/build.
- Mond loading on iOS 16.1+ does not make an exploit-backed filesystem grant universal across iOS versions.
- PosterBoard/Tendies application requires writable access to the required PosterBoard data location.
- `/System/Library` can be readable while remaining on iOS's signed read-only system volume.
- Access to an App Group or data container does not imply access to the entire filesystem.
- Kernel read/write is not established by this project.
- No full jailbreak, root shell, SPTM bypass, or system-volume remount is claimed.
- WebDAV and SSH are app-hosted services and can be suspended in the background.

## Upstream projects and credits

Filza-27 combines work from multiple open-source projects. Their upstream licenses and notices remain part of the repository.

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
