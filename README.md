# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork combining Filza with app/container management, ByeTunes, Mond 2.2, WebDAV, SSH/SFTP, and the 3105 patch workspace.

[![Release](https://img.shields.io/github/v/release/NightVibes33/Filza-27?display_name=tag&label=latest)](https://github.com/NightVibes33/Filza-27/releases/latest)

## Download

### [Download the latest `Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

- Minimum deployment target: **iOS 17.0**.
- Checksum: [`Filza-27-SHA256.txt`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27-SHA256.txt)
- Public releases are produced from an exact-SHA green GitHub Actions build on `main`.

> **This is not a full jailbreak.** Filza-27 exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## Modern iOS 17+ architecture

Filza-27 ships one integrated arm64 runtime for **iOS 17.0+**:

- `Frameworks/FilzaApplySandboxExt.dylib` contains the Filza integration, full pinned Mond 2.2 host, 3105 1.1.1, ByeTunes, WebDAV, SSH/SFTP, Gestalt routing, and runtime hooks.
- There is **no separate `FilzaMondModern.dylib`** and no iOS 16 compatibility transform.
- The release packager removes any stale split Mond runtime from the base IPA and asserts `MinimumOSVersion = 17.0`.
- FilzaSlop packaging hardening strips `CFBundleURLTypes` from the packaged app and fails packaging if URL handlers remain.

## Upstream FilzaSlop sync

Filza-27 is synchronized through **`0xjohnnydev/FilzaSlop@ec490ade64b7755544833248d915e4adfc6f80d6`**. This covers the seven upstream commits GitHub previously reported as missing from this branch history:

- `583fc09` — iOS 26 third-party app discovery through the accessible LaunchServices store.
- `b7abe0d` — jailed container delete action fixes.
- `5458ee7` — LiveContainer compatibility.
- `dc10a15` — archive-first removal and safer deletion.
- `75228a7` — explicit experimental LiveContainer warning.
- `faad157` — simplified documented path list.
- `ec490ad` — release IPA URL-scheme stripping.

Filza-27 keeps its downstream runtime integrations and modern iOS 17+ packaging while retaining those upstream fixes.

## What's new

### FilzaSlop upstream runtime updates

- iOS 26 app discovery recovers third-party identifiers from the device-local LaunchServices store and validates them through direct class-2 ContainerManager lookups.
- LiveContainer compatibility uses guest-specific roots and signed-code identity checks.
- Archive-first removal and safer permanent-delete confirmation are used for MCM-backed items.
- Generated-file deletion tracking keeps intentionally removed generated files absent.
- Release IPA URL schemes are stripped with an explicit packaging assertion.

### Full Mond 2.2 on the modern runtime

- Mond pinned to `rooootdev/mond@3d91194716ad5f06afdf7e9037e6964e80a4ac29`.
- Mond is compiled directly into the main Filza runtime rather than lazy-loaded from a second compatibility dylib.
- **CacheExtra Fields**, **MobileGestalt**, **PosterBoard / Tendies**, **HouseArrest / Santander**, and exploit/settings routes are retained.
- **Run Exploit**, **Generate Token**, **Persist after reboot**, and **Ignore exploit failure** retain the upstream Mond flow.
- The generated embedded copy keeps the Mond defaults domain, resources, namespace, shared state, and host adapters required to run inside Filza.

### 3105 1.1.1 + unified third-party presentation

- 3105 is pinned to `YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa` (**1.1.1**).
- The Files/Patches workspace, app/container handling, IPA repackaging, and current backend source units remain integrated.
- 3105 and ByeTunes retain their shared persisted pairing/device connection.
- 3105 keeps SpringBoardServices icon upgrades with LaunchServices fallback where available.
- 3105, Mond, and presented ByeTunes use the same `FilzaEmbeddedPanel` shell for Close/dismissal behavior.
- Filza's own file-browser/navigation UI is not replaced by that shared shell.

See [`RELEASE_NOTES.md`](RELEASE_NOTES.md) for the release changelog.

## Included features

| Feature | Status | Notes |
| --- | --- | --- |
| Filza file browser | ✅ | Visibility still follows actual sandbox/access state |
| Apps Manager | ✅ 3105 1.1.1 | App/container details depend on available APIs/permissions |
| iOS 26 app discovery | ✅ | LaunchServices store candidates + direct MCM validation |
| Shared device pairing | ✅ | Used by ByeTunes/3105 paired features |
| Enhanced app icons | ✅ where supported | SpringBoardServices with LaunchServices fallback |
| `.3105` Patch Workspace v2 | ✅ | Portable projects, backup/restore, receipts/journals |
| 3105 IPA repackaging | ✅ | Repackages the installed app bundle without decrypting FairPlay |
| Music Library / ByeTunes | ✅ | Embedded ByeTunes integration |
| YouTube metadata provider | ✅ | Required solver resources packaged |
| Mond 2.2 UI/runtime | ✅ | Integrated directly into the iOS 17+ core |
| MobileGestalt editor | ✅ | Mond route |
| CacheExtra Fields | ✅ | Current Mond 2.2 route |
| PosterBoard / Tendies | ✅ | Applying changes still depends on writable target access |
| HouseArrest / Santander | ✅ | Access remains OS/build-specific |
| WebDAV server | ⚠️ Runtime unverified | App-hosted listener builds successfully, but device behavior is currently unverified and likely broken |
| SSH/SFTP server | ⚠️ Runtime unverified | wolfSSH/SFTP builds successfully, but real device connections and background behavior are currently unverified and likely broken |
| Home Screen quick actions | ✅ | Apps Manager, Music Library, Gestalt, and Patches routes |
| Shared third-party panel | ✅ | 3105, Mond, presented ByeTunes; Filza browser UI unchanged |
| Full jailbreak / writable system volume | ❌ Not claimed | Outside this project's proven capabilities |

## Compatibility

The application and integrated runtime build with a minimum deployment target of **iOS 17.0**.

UI availability and filesystem-access capability are separate. Mond's `bad_query`, `cmg`, private APIs, 3105 backend paths, and cross-container write paths remain OS/build-specific. Filza-27 validates what access is actually available on the running device rather than treating the UI as proof of unrestricted access.

For iOS 27 research builds, useful `bad_query` behavior is associated with specific builds; do not infer unrestricted access merely because Mond loads.

### Experimental LiveContainer compatibility

> [!WARNING]
> LiveContainer compatibility is **experimental**. This mode does **not** provide MobileHouseArrest access to App Store apps or other apps installed by iOS. It exposes only guest apps and data stored inside the active LiveContainer environment.

The normal standalone MobileHouseArrest path requires the signed code identity `com.apple.mobile.MobileHouseArrest`. Running Filza-27 as a LiveContainer guest uses the LiveContainer host identity instead, so system app-container access should not be expected in that mode.

## Upstream path coverage

When the current OS/build and active access primitive authorize them, the upstream FilzaSlop integration targets these roots:

```text
/private/var/mobile/Containers/Data/Application/
/private/var/mobile/Containers/Shared/AppGroup/
/private/var/mobile/Containers/Data/PluginKitPlugin/
/private/var/mobile/Containers/Data/VPNPlugin/
/private/var/mobile/Containers/Data/InternalDaemon/
/private/var/mobile/Containers/Data/System/
/private/var/mobile/Containers/Shared/SystemGroup/
/private/var/mobile/Containers/Data/Protected/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/
```

These are capability-dependent targets, not a claim that every path is writable or available on every iOS build.

## Install

1. Download `Filza-27.ipa` from the latest release.
2. Sideload it with your preferred signing method.
3. Keep the base app identity when your signer allows it:

```text
com.apple.mobile.MobileHouseArrest
```

Changing that identity can break MobileHouseArrest-dependent behavior.

## Main tools

### Apps Manager / 3105

Apps Manager embeds **3105 1.1.1** from:

```text
YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa
```

It includes app search, icon and disk-size recovery where available, container browsing, independent Files tabs, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, IPA repackaging support, and Patch Workspace handoff.

Because 3105 is embedded rather than process owner, Filza does not compile its standalone `@main` lifecycle or install standalone-global window/process hooks into the Filza host. See `ThirdParty/3105/UPSTREAM.md` for the embedding boundary.

### Music Library / ByeTunes

ByeTunes is embedded directly into Filza-27 and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The integration retains the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider. Required JavaScript solver resources are packaged inside the IPA.

### Mond 2.2 / Gestalt / PosterBoard

Available Mond routes include:

- MobileGestalt
- CacheExtra Fields
- PosterBoard / Tendies
- HouseArrest / Santander
- Settings / exploit controls

Exposed Mond access methods include `bad_query` and `cmg`. Their effectiveness remains version/build-specific.

The MobileGestalt cache used by the editor is:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

## SSH/SFTP

> [!WARNING]
> SSH/SFTP device-runtime behavior is currently unverified and likely broken. A green build confirms compilation and packaging only; it does not prove that an interactive SSH or SFTP client can complete a working session.

The server uses the pinned wolfSSH/wolfSSL stack, listens on the configured TCP port, and is intended to support password-authenticated interactive shell and SFTP sessions. Multiple SSH `session` channels are enabled because clients such as Clauntty open a control PTY before opening their actual terminal or setup channel.

For a device at `192.168.4.20` using port `2222`:

```sh
ssh filza@192.168.4.20 -p 2222
sftp -P 2222 filza@192.168.4.20
```

The app activates an audio-mode keepalive while SSH/SFTP is enabled so an established listener can continue when Filza moves to the background. Force-quitting the app, process termination, or the OS revoking execution still stops an in-process server.

The displayed private address is reachable only on the local network (and can also be used by a terminal app on the same device). Remote Internet access requires a successful router mapping, a manually configured forward, or a separate VPN/tunnel. A NAT-PMP/UPnP failure is a public-mapping failure, not an SSH listener failure.

## Shared third-party UI contract

`ThirdParty/3105/Sources/FilzaEmbeddedPanel.swift` is the canonical host shell for presented third-party tools. It provides the persistent Close action, material header/divider, page-sheet presentation, large detent, grabber, and consistent dismissal behavior.

3105, Mond, and the normal presented ByeTunes route consume that component while keeping their own internal views and features. This does not modify Filza's file-browser UI.

## Logs

Runtime logs are stored under:

```text
Documents/FilzaSlop Logs/
```

Useful files include `Runtime.log`, `WebDAVStatus.txt`, `SSHStatus.txt`, and `ByeTunesEmbedStage.txt`.

## Verification and releases

The production modern IPA verifier is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```

The 3105/shared-presentation source contract is:

```text
.github/workflows/verify-3105-shared-ui.yml
```

The old iOS 16 and universal split-runtime workflows are disabled and do not build or publish artifacts. After the exact-SHA modern verifier succeeds, the release workflow publishes:

```text
Filza-27.ipa
Filza-27-SHA256.txt
```

## Current limitations

- WebDAV and SSH/SFTP device-runtime behavior is currently unverified and likely broken despite green compilation and packaging checks.
- A green Actions build proves compilation, linking, deployment target, packaging, and artifact structure; it cannot prove every private API behaves identically on every device/build.
- PosterBoard/Tendies application requires writable access to the required PosterBoard data location.
- `/System/Library` can be readable while remaining on iOS's signed read-only system volume.
- Access to an App Group or data container does not imply access to the entire filesystem.
- No full jailbreak, root shell, SPTM bypass, or system-volume remount is claimed by the packaging work.
- WebDAV is app-hosted and may be suspended in the background. SSH/SFTP requests audio-mode background execution while enabled, but cannot survive a force-quit or process termination.

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
