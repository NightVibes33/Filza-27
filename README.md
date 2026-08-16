# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork for modern iOS with extra container access, app management, music tools, MobileGestalt editing, WebDAV, and SSH built into one IPA.

[![Verified IPA](https://github.com/NightVibes33/Filza-27/actions/workflows/verify-upstream-byetunes-ssh.yml/badge.svg?branch=main)](https://github.com/NightVibes33/Filza-27/actions/workflows/verify-upstream-byetunes-ssh.yml)

[**Download the current green `Filza-27.ipa` Release**](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)

**Current verified Release:** `filza-27-51` — built from `740115322ff90b68cafb49420f75008492f2d467` after workflow run `31918082498` completed successfully.

**Release rule:** `Filza-27.ipa` is published only after the full IPA workflow finishes green on `main`.

> **This is not a full jailbreak.** FilzaSlop only exposes files and containers the running app can actually access. It does not claim unrestricted `/`, kernel read/write, or a writable system volume.

## What is included

| Feature | Status |
| --- | --- |
| Latest Release IPA | ✅ Published only from a green verified build |
| Filza file browser | ✅ Included |
| Apps Manager / app containers | ✅ Integrated |
| Portable `.3105` patches | ✅ Integrated |
| Music Library / ByeTunes | ✅ Integrated |
| YouTube metadata provider | ✅ Restored and bundled |
| MobileGestalt editor / Mond | ✅ Integrated |
| WebDAV server | ✅ In-process server |
| SSH server | ✅ In-process libssh server |
| Home Screen quick actions | ✅ Apps Manager, Music Library, Gestalt Editor, Patches |
| Full root filesystem / jailbreak | ❌ Not provided |

## Compatibility

This fork is aimed at the iOS 18 / iOS 26 / early iOS 27 behavior used by the bundled container-access methods.

For iOS 27, the useful `bad_query` behavior is associated with beta 1–4. **Do not assume the same access on beta 5 or newer**, where that primitive was patched. The Gestalt catalog can still contain keys identified on newer betas even when the access primitive itself is unavailable.

Exact access can vary by device and iOS build, so the app verifies real file or directory access instead of treating a returned handle as automatic success.

## Download and install

1. Download **[`Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/latest/download/Filza-27.ipa)** from the latest verified GitHub Release.
2. Sideload it with your preferred signing method.

The Release asset is created automatically from the newest successful **Verify ByeTunes All Sources + YouTube + SSH IPA** run on `main`, so a failed build is never promoted as the latest IPA.

### Important signing note

Keep the base app identity:

```text
com.apple.mobile.MobileHouseArrest
```

Changing the bundle identifier can break the MobileHouseArrest-dependent access path.

## Quick start

The main Filza toolbar and Home Screen quick actions expose the four main additions:

- **Apps Manager**
- **Music Library**
- **Gestalt Editor**
- **Patches**

### Apps Manager

Apps Manager opens the integrated 3105 workspace and can browse applications and the containers that are actually reachable from the current process.

It includes:

- application search;
- app icons and disk-size recovery where available;
- foreign app data-container fallback;
- file preview;
- create, rename, import, replace, and delete operations;
- Cleaner and Wallpaper Lab tools;
- direct handoff from Files into portable patch projects.

A container is only treated as available after real directory access succeeds.

### Patches

The Patches page uses the same 3105 workspace as Apps Manager.

It supports portable `.3105` projects with:

- create, edit, import, and export;
- bundle-ID based targets so projects are not tied to one container UUID;
- optional password protection;
- backups and receipts;
- apply and restore flows.

### Music Library

The full ByeTunes music-management UI is embedded directly into FilzaSlop.

On first use, select a valid pairing file. ByeTunes saves a persistent copy and attempts to reuse it on later launches. If the saved pairing state is rejected, select the pairing file again.

The embedded build includes:

- device-library browsing;
- downloads and queue persistence;
- backup / restore and repair tools;
- metadata editing;
- Apple Music, iTunes, Deezer, YouTube, and **All Sources** metadata routing;
- Live Activity support where iOS allows it.

#### YouTube metadata

The current build keeps ByeTunes v2.4 while restoring the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider before mirror fallbacks.

The required JavaScript solver resources are bundled inside the IPA, so no extra files need to be installed manually.

Useful log messages include:

```text
[YouTubeProvider] YouTubeKit metadata matched videoID=...
[YouTubeProvider] YouTubeKit metadata failed: ...
```

### Gestalt Editor

Gestalt Editor uses a pinned Mond integration adapted for FilzaSlop and opens directly from the app.

The editor can inspect supported MobileGestalt values and, when the underlying file is actually writable, apply changes with backup and read-back validation.

Open the gear in Gestalt Editor for Mond settings. The available access methods are:

- `bad_query`
- `cmg`

Typical flow:

1. Choose the access method.
2. Press **Run Exploit**. Opening Mond by itself does not run the exploit.
3. After access succeeds, press **Generate Token** if you want Mond to issue and display a fresh MobileGestalt sandbox extension token.
4. Return to the editor and use Apply / Revert normally.

The token UI no longer reuses the sandbox token consumed internally by `bad_query`. **Generate Token** requests a fresh read-write sandbox extension after exploit access is active.

The MobileGestalt cache used by the editor is:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

The editor includes the newer iOS 27 capability mappings in addition to the existing Dynamic Island, Always-On Display, Camera Control, Action Button, Stage Manager, Apple Intelligence eligibility, internal-feature, and related controls.

### WebDAV

FilzaSlop runs WebDAV inside the app instead of trying to use Filza's jailbreak-only launch daemon path.

Enable it from:

**Preferences → Advanced options → Enable WebDAV server**

Default port:

```text
11111
```

Accept the iOS **Local Network** permission prompt the first time. For the most reliable transfers, keep FilzaSlop in the foreground because iOS can suspend sideloaded apps in the background.

The exact listening address is written to the logs described below.

### SSH

FilzaSlop also contains a real in-process libssh server.

Open **Preferences → SSH SERVER** to configure:

- **Port** — default `2222`
- **Bonjour** — enabled by default
- **Authentication** — enabled by default
- **Username** — default `filza`
- **Password** — set your own password before enabling the server

Then turn on **Enable SSH server**. The connection address is shown in the SSH section footer.

Example:

```sh
ssh filza@192.168.1.50 -p 2222
```

The embedded shell intentionally exposes a small useful command set rather than pretending to be a full iOS userland. Commands include `pwd`, `cd`, `ls`, `cat`, `stat`, `mkdir`, `touch`, `cp`, `mv`, `rm`, `chmod`, `readlink`, `df`, `whoami`, `id`, `uname`, `echo`, `clear`, `help`, and `exit`.

Filesystem permissions over SSH are **exactly the same permissions the FilzaSlop process has**.

FilzaSlop can also request direct router port mapping with NAT-PMP or UPnP when the network supports it. It only reports a public endpoint after a mapping is confirmed and a globally routable IPv4 address is detected. CGNAT or double-NAT is reported instead of showing a fake public address.

Do not expose SSH publicly without authentication.

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

These are the first files to check when a server, Music Library, or access method behaves differently on a specific iOS build.

## Current limitations

- A green GitHub Actions build proves the source compiled, linked, packaged, and uploaded successfully. It cannot prove every private API behaves the same on every iOS build.
- `/System/Library` may be readable or enumerable while still living on iOS's signed read-only system volume.
- Access to an App Group or data container does not imply access to the entire filesystem.
- Kernel read/write is not established by this project.
- No full jailbreak, root shell, SPTM bypass, or system-volume remount is claimed here.
- WebDAV and SSH are app-hosted services and may be suspended when iOS backgrounds the app.

## Building

Normal users do not need to build the project manually; use the verified Release IPA above.

<details>
<summary><strong>GitHub Actions build details</strong></summary>

The current installable IPA workflow is:

```text
.github/workflows/verify-upstream-byetunes-ssh.yml
```

It verifies the pinned dependencies, builds the arm64 runtime, generates ByeTunes AppIntents metadata, stages the required Music Library and YouTubeKit resources, injects everything into the pinned unsigned Filza base IPA, verifies the final package, and uploads the artifact.

After that workflow finishes successfully, `.github/workflows/publish-green-ipa-release.yml` republishes that exact verified artifact to GitHub Releases as:

```text
Filza-27.ipa
```

The workflow currently builds with Xcode 26.2.

</details>

<details>
<summary><strong>Local Theos build</strong></summary>

```sh
export THEOS="$HOME/theos"
make clean
make all FINALPACKAGE=1 TARGET=iphone:clang:latest:16.0
```

The runtime dylib is written to:

```text
.theos/obj/FilzaApplySandboxExt.dylib
```

</details>

## Upstream projects and credits

FilzaSlop combines work from several open-source projects. Their upstream licenses and notices remain part of the repository.

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

## Research notes

The repository also contains diagnostics and compatibility work for container-access and filesystem behavior on modern iOS. Those experiments should be treated as research features, not as proof of unrestricted system access.
