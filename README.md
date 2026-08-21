# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork combining Filza with app/container management, ByeTunes, Mond 2.2, WebDAV, SSH, and the 3105 patch workspace.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### [Download the latest `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

- Checksum: [`Filza-27-SHA256.txt`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27-SHA256.txt)
- Every public release is produced from an exact-SHA green GitHub Actions build on `main`.


> **This is not a full jailbreak.** Filza-27 exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## Modern iOS 17+ architecture


## What's new

### Full Mond 2.2 on modern iOS

- Mond pinned to `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- **CacheExtra Fields** editor included.
- **Persist after reboot** and **Ignore exploit failure** settings included.
- **MobileGestalt**, **PosterBoard / Tendies**, and **HouseArrest / Santander** routes included.
- **Run Exploit** and **Generate Token** retain the upstream Mond flow.
- Tendies `Observation/@Observable` state is backported to Combine `ObservableObject/@Published`.
- Current MobileGestalt persistence and iOS 27 region-key behavior from the pinned upstream revision are retained.

### 3105 1.1.1 + unified third-party presentation

- 3105 is pinned directly to official upstream `YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa` (**1.1.1**).
- The current Files/Patches workspace, 1.1.1 tap behavior, support-policy updates, and existing 1.1.1 backend source units used by Filza are staged before compilation.
- 3105 and ByeTunes keep their shared persisted pairing/device connection.
- 3105 keeps broader app enumeration and SpringBoardServices icon upgrade with LaunchServices fallback.
- **3105, Mond, and presented ByeTunes now use the exact same `FilzaEmbeddedPanel` presentation source**: persistent material Close bar, divider, large page sheet, visible grabber, and the same dismissal behavior.
- Each third-party app keeps its own internal UI/features inside that common shell.
- **Filza's own file-browser/navigation UI is not restyled or replaced.**
- Standalone 3105 process/window hooks that would affect the host globally are not installed into Filza.

The untouched upstream Mond source snapshot remains under `ThirdParty/mond-current/Upstream`; the generated embedded Mond copy retains its explicit AccentColor, `com.roooot.mond` defaults domain, resource bundle, namespace, and shared-state adapters.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog.

## Included features

| --- | --- | --- |
| Filza file browser | ✅ | Actual filesystem visibility still follows sandbox/access state |
| Apps Manager | ✅ 3105 1.1.1 | App/container details depend on available APIs/permissions |
| Shared device pairing | ✅ | Used by ByeTunes/3105 paired features |
| Enhanced app icons | ✅ where supported | SpringBoardServices with LaunchServices fallback |
| `.3105` Patch Workspace v2 | ✅ | Portable projects, backup/restore, receipts/journals |
| 3105 IPA repackaging | ✅ | Included in the single IPA |
| Music Library / ByeTunes | ✅ | Full embedded ByeTunes integration |
| YouTube metadata provider | ✅ | Required solver resources packaged |
| Mond 2.2 UI/runtime | ✅ | Mond dylib itself has minOS 16.1 |
| MobileGestalt editor | ✅ | Mond route; native Gestalt remains fallback |
| PosterBoard | ✅ | Store 59 on iOS16, 61 on iOS17+ |
| Tendies browser/download/import | ✅ | Applying requires writable PosterBoard access |
| HouseArrest / Santander | ✅ | Direct access first; exploit-backed grants remain version-specific |
| WebDAV server | ✅ | App-hosted service |
| SSH server | ✅ | App-hosted service |
| Home Screen quick actions | ✅ | Mond/Gestalt routing preserved on iOS16 |
| Shared third-party Close/page-sheet UI | ✅ | Same source for 3105, Mond, presented ByeTunes; Filza UI unchanged |
| Full jailbreak / writable system volume | ❌ Not claimed | Outside this project's proven capabilities |

## Compatibility

The application and integrated runtime build with a minimum deployment target of **iOS 17.0**.

That does not mean every access primitive works on every OS version. Mond's `bad_query`, `cmg`, private APIs, 3105 backend paths, and cross-container write paths remain OS/build-specific. Filza-27 keeps the UI/runtime portable while validating what access is actually available on the running device.


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

Apps Manager embeds **3105 1.1.1**, pinned to the official upstream release commit:

```text
YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa
```

It includes application search, icon and disk-size recovery where available, container browsing, independent Files tabs, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, IPA repackaging support, Patch Workspace handoff, and the current 1.1.1 support/backend state used by the embedded build.

Pairing remains an optional icon-quality backend rather than a replacement for app enumeration. When the shared ByeTunes/Filza connection is ready, 3105 can request rendered SpringBoardServices icons; otherwise LaunchServices icons remain available.

Because 3105 is embedded rather than process owner, Filza does not compile its standalone `@main` lifecycle or install standalone-global window/process hooks into the Filza host. See `ThirdParty/3105/UPSTREAM.md` for the exact embedding boundary.

### Patches

The embedded **3105 Patch Workspace v2** supports portable `.3105` projects, schema-v2 workspaces, legacy v1 decoding, bundle-ID targets, directory targets, import/export, backups, receipts, transaction journals, and restore flows.

### Music Library / ByeTunes

ByeTunes is embedded directly into Filza-27 and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The integration restores the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider while retaining current ByeTunes behavior. Required JavaScript solver resources are packaged inside the IPA.

ByeTunes owns the canonical pairing/device connection used by paired features, and 3105 consumes that same persisted state.

The normal presented ByeTunes route uses the same `FilzaEmbeddedPanel` as 3105. The legacy Filza-owned Music Library child-controller path remains a raw `ContentView` only to avoid nesting a second modal shell inside an existing Filza controller.

### Mond 2.2 / Gestalt / PosterBoard


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


## Shared third-party UI contract

`ThirdParty/3105/Sources/FilzaEmbeddedPanel.swift` is the single canonical host shell for presented third-party tools. It supplies:

- persistent top-left **Close** action;
- material header and divider;
- `.pageSheet` presentation;
- large detent;
- visible sheet grabber;
- consistent dismissal behavior.

3105, Mond, and the normal presented ByeTunes route consume that exact component rather than maintaining separate look-alike copies. Their internal app views remain independent. This contract does **not** modify Filza's own UI.

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

The production modern IPA verifier is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```




After the exact-SHA universal and full-feature verifiers succeed, the release workflow publishes only:

```text
Filza-27.ipa
Filza-27-SHA256.txt
```

## Current limitations

- A green Actions build proves compilation, linking, deployment targets, packaging, and artifact verification; it cannot prove every private API behaves identically on every device/build.
- PosterBoard/Tendies application requires writable access to the required PosterBoard data location.
- `/System/Library` can be readable while remaining on iOS's signed read-only system volume.
- Access to an App Group or data container does not imply access to the entire filesystem.
- No full jailbreak, root shell, SPTM bypass, or system-volume remount is claimed by the universal packaging work.
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
