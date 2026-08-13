# FilzaSlop

A jailed Filza fork focused on iOS container access, application metadata recovery, MobileGestalt inspection/editing, and embedded utility experiments on modern iOS.

This fork currently targets the iOS 18 / iOS 26 / early iOS 27 behavior exposed by the bundled container-access primitives. The iOS 27 Gestalt catalog also includes keys identified through beta 5, but that does **not** imply every underlying access primitive works on beta 5.

> **Important:** this project does not claim unrestricted root filesystem access. Paths are only exposed after the process can actually open/enumerate them. A returned access handle by itself is not treated as proof that a directory is usable.

## Current status

| Area | Status |
| --- | --- |
| Real unsigned arm64 IPA build | ✅ CI builds and uploads a real IPA |
| App container discovery | ✅ Integrated |
| Foreign app data-container fallback | ✅ Integrated |
| App size metadata retry | ✅ Integrated |
| App icon fallback | ✅ Integrated |
| Gestalt Editor | ✅ Complete editor is linked into the main toolbar route |
| Gestalt Home Screen quick action | ✅ Static action and runtime handler are both linked |
| iOS 27 Gestalt key catalog | ✅ Included |
| Music Library resources | ✅ Packaged into the IPA |
| Music Library integration | ✅ Complete UI opens directly without an intermediate loading or splash screen |
| WebDAV server | ✅ Redirected to Filza's in-process server for jailed/sideloaded use |
| Arbitrary `/` / full system filesystem access | ❌ Not established |

## Managers

### Apps Manager

The fork keeps Filza's Apps Manager path and adds compatibility work for modern iOS application discovery and metadata.

Current behavior includes:

- LaunchServices-backed application discovery fallback.
- Direct ContainerManager identifier validation.
- `bad_query_list()` fallback for foreign application data containers when normal lookup does not provide usable access.
- Container access is considered successful only after directory access can be verified.
- App disk usage is retried after a real foreign data-container path becomes available instead of permanently showing `0 KB` from the initial inaccessible path.
- App icon lookup includes a MobileIcons resource-proxy fallback and format `10` before older formats.

### Music Library

The complete upstream music-management implementation is compiled into the arm64 target and its runtime resources are copied into the final app bundle.

The packaged IPA includes:

```text
meriyah.umd.js
astring.umd.js
yt_ejs_helper.js
AppIconImage.png
ByeTunes-Info.plist
```

The Music Library action intercepts `TGMainView.openMusicLib` and constructs the
complete SwiftUI `ContentView` immediately. The Home Screen Music Library action uses
the same presenter. There is no intermediate UIKit loading controller, branded splash,
or artificial delay. `TGMusicLibraryViewController` remains only as a fallback route.
Imported pairing files are copied into FilzaSlop's persistent Documents container. On
later launches the embedded manager validates that saved copy, skips the import screen,
and reconnects automatically; the document picker is shown only when no valid saved
pairing file exists.

A runtime stage marker is written to:

```text
Documents/FilzaSlop Logs/ByeTunesEmbedStage.txt
```

The stage log records the factory call, `ContentView` construction, hosting-controller
construction, view materialization, and final attachment. CI proves the complete source
is compiled and linked into the IPA; the installed build still requires device runtime
validation.

### Gestalt Editor

The complete Gestalt editor is compiled into the Filza runtime. A **Gestalt Editor**
action is inserted beside the existing Apps Manager and Music Library entries, with a
`TGMainView` toolbar hook as a second in-app route.

It is also exposed as a static Home Screen quick action:

```text
Gestalt Editor
Edit MobileGestalt
```

Both the in-app button and Home Screen quick action open the same editor directly with
no intermediate loading controller. MobileGestalt access is prewarmed after launch;
an access failure is shown as a normal error alert instead of a fake editor screen.
The editor attempts to resolve:

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

Access flow:

1. Query the MobileGestalt system-group container through ContainerManager.
2. Activate the returned sandbox extension when available.
3. Fall back to the bundled directory-access primitive when required.
4. Verify the actual MobileGestalt plist is readable before exposing it.
5. Detect whether the file is read-only or read/write.

Write handling includes:

- one-time backup before modification;
- property-list serialization validation;
- atomic write when possible;
- direct file-descriptor fallback when necessary;
- post-write plist read-back validation;
- automatic restoration of the backup if validation fails.

The editor follows `rooootdev/mond` GestaltView at upstream commit
`50b76a500b34d70119e30e04921dcb138c284855`: complete device-artwork, software,
hardware, eligibility, iPadOS, internal-feature, spoofing, Apply, and Revert controls;
the same device/version gating; and the same warning and information dialogs. Filza's
verified write bridge replaces Mond's standalone exploit lifecycle while preserving
property-list read-back validation and automatic backup restoration.

### WebDAV server

Filza's original **Run as system service** option targets jailbreak-only `launchctl`
and `/usr/libexec/filza/FilzaWebDAVServer` paths. Those paths cannot work from the
sideloaded MobileHouseArrest app container. FilzaSlop now links a pinned complete
`GCDWebDAVServer` implementation and forces WebDAV through that in-process server
while preserving Filza's port, Bonjour, authentication, WebDAV methods, and
shared-folder settings. The runtime hooks Filza's actual `swithAirBrowserCheckbox`
action (the selector is misspelled in Filza itself) and the underlying
`air-browser` preference write/removal, so the visible switch now starts and stops
the in-process listener instead of only changing its stored value. It implements
OPTIONS, PROPFIND, GET/HEAD, PUT, MKCOL,
DELETE, COPY, MOVE, LOCK, and UNLOCK. When Filza authentication is enabled, the
server validates HTTP Basic credentials against Filza's saved password hash and
refuses to start if those credentials are incomplete.

Use **Preferences → Advanced options → Enable WebDAV server**. The default port is
`11111`; the exact listening URL and root are recorded after every start or resume in:

```text
Documents/FilzaSlop Logs/WebDAVStatus.txt
Documents/FilzaSlop Logs/Runtime.log
```

The IPA declares local-network and `_http._tcp` Bonjour usage, so accept the iOS Local
Network prompt the first time the server starts. Keep FilzaSlop in the foreground while
transferring files: a sideloaded app cannot install a persistent launch daemon, and iOS
may suspend its listener in the background. Returning to the app automatically checks
and restarts the listener when WebDAV remains enabled.

## iOS 27 Gestalt keys

The current catalog contains these newer keys identified through iOS 27 beta 5:

| Key | Name |
| --- | --- |
| `7brdL5xrEUWnlF9C0kdg5A` | `DeviceSupportsHighLuminanceAlwaysOnDisplay` |
| `A/74xUbqJwBsaWTjSDd0fQ` | `ChassisSlotFunctionNumber` |
| `a3n5T9sFtlyQ74NEp9ESxg` | `SiriMode` |
| `HBG+hj/Oz89PjVgn93Jd8A` | `Image4SecureBootKeyScheme` |
| `ikn/KMyeztXJhAj/dqBjBg` | `LowPowerRendererCapability` |
| `J2+oJRiGdbAzTi6U5nhqdQ` | `PostQuantumCryptographyEnforced` |
| `Kpfa0nb8nn8EVzI/UgcMfQ` | `CoalescedSubTargetID` |
| `lyJZrSDc8J8eQ5b7A1Rvw` | `DeviceSupportsTouchSensitiveCameraControl` |
| `m4xs4mhvxnAopYrApoLDMw` | `DeviceSupportsInstructionFollowingPruningModels` |
| `mnPU37/y4i0TJFnJc+r4lA` | `DeviceSupportsLowPowerWake` |
| `odI0U9Etrx7hObzvJ9xJ8Q` | `DeviceSupportsSandcat` |
| `P4ZJVy/zYuLy4ejRKP+0DA` | `DeviceSupportsRegionalCameraShutterRelaxation` |
| `qqrspu7CpuPdZwSDxNY+Fg` | `MaximumFlipbookCount` |
| `s1ZXqZtUSpr+BjUgZXZ/2g` | `ChassisSlotInstanceNumber` |
| `TusANsf9Lfe3P/9fIXXSrQ` | `DeviceSupportsAlwaysListeningHeySiri` |
| `VXc3L66nqQ6bn4z60ChX+A` | `ResponsiveAirPlayAudioCapability` |
| `ym8C/Ut5YcBnqAdm4NEDLQ` | `Image4SecureBootCertificateFormat` |

The manager also includes older feature mappings for items such as Dynamic Island, Always-On Display, Camera Control, Action Button, Stage Manager, Apple Intelligence eligibility, internal features, and related capability flags.

## Filesystem paths

### Container roots

```text
/private/var/mobile/Containers/Data/Application/
/private/var/mobile/Containers/Shared/AppGroup/
/private/var/mobile/Containers/Data/PluginKitPlugin/
/private/var/mobile/Containers/Data/VPNPlugin/
/private/var/mobile/Containers/Data/InternalDaemon/
/private/var/mobile/Containers/Data/System/
/private/var/mobile/Containers/Shared/SystemGroup/
/private/var/mobile/Containers/Data/Protected/
```

### Additional known paths

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/
```

The system-path probe also checks selected higher-level paths, but a path is not presented as usable merely because a query returned a handle. Actual `opendir` / `readdir` success is required.

### Notable app data

```text
# Notes
/private/var/mobile/Containers/Shared/AppGroup/<Notes-group-UUID>/NoteStore.sqlite

# Safari app data
/private/var/mobile/Containers/Data/Application/<Safari-app-UUID>/

# Safari shared data: group.com.apple.safari
/private/var/mobile/Containers/Shared/AppGroup/<Safari-group-UUID>/
```

## PosterBoard

Wallpaper Lab can:

- Inspect the PosterBoard descriptor store.
- Import the bundled Cipher wallpaper.
- Import extracted `.tendies` wallpaper packages.
- Apply the PosterBoard refresh preferences.
- Roll back the latest import.

Place additional packages in:

```text
Documents/Device Storage/[MHA-C2] Wallpaper Lab/Imports/
```

Use the **Wallpaper** button at the Wallpaper Lab root. Imports add new descriptor directories and keep a rollback backup. They do not overwrite the PosterBoard database or existing descriptors.

## Signing

Keep the MobileHouseArrest bundle / CodeDirectory identity used by the base app:

```text
com.apple.mobile.MobileHouseArrest
```

Changing that identity can break the MobileHouseArrest-dependent access path.

## Building

### Local dylib build

```sh
export THEOS="$HOME/theos"
make clean
make all FINALPACKAGE=1 TARGET=iphone:clang:latest:16.0
```

The resulting runtime dylib is:

```text
.theos/obj/FilzaApplySandboxExt.dylib
```

### Real unsigned IPA in GitHub Actions

The repository workflow:

```text
.github/workflows/verify-safe-fixes.yml
```

now performs the complete installable build:

1. verifies pinned source dependencies;
2. syntax-checks the Objective-C runtime integrations;
3. builds and links the complete arm64 target;
4. stages ByeTunes runtime resources;
5. downloads and hash-verifies the pinned unsigned Filza base IPA;
6. injects the current runtime dylib and resources;
7. writes exactly three Home Screen shortcuts plus Local Network/Bonjour declarations into `Info.plist` and assigns build version `4.4`;
8. verifies the base executable actually loads `FilzaApplySandboxExt.dylib`;
9. repacks a real unsigned IPA;
10. uploads the IPA as a GitHub Actions artifact.

The workflow is configured so a missing upload is a build failure rather than a warning.

Current artifact name:

```text
FilzaSlop-installable-unsigned-arm64
```

Open **Actions → Verify Filza installable IPA** to download the latest build artifact.

## Current limitations

- A green build proves the current source compiled, linked, packaged, and uploaded successfully. It does **not** prove every private API or sandbox-extension path still works on a specific iOS build.
- Music Library, Gestalt Editor, and WebDAV should be revalidated on-device after each new IPA build.
- The existing container-access primitives do not establish unrestricted `/`, `/System`, `/Library`, `/Applications`, or arbitrary `/private` traversal.
- No kernel read/write or full jailbreak primitive is claimed by this README.

## PoCs / upstream research

- [MobileHouseArrest](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [Geod MCM](https://github.com/0xjohnnydev/Geod-MCM-PoC)
- [InstallCoordination](https://github.com/0xjohnnydev/InstallCoordination-PoC)
- [CFPrefs zero-file](https://github.com/0xjohnnydev/CFPrefsZeroFile-PoC)

## Credits

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- CrazyMind90
- XPF and ChOma contributors
- `SerStars/nugget-wallpapers`
- mightycooldude12
- [`rooootdev/mond`](https://github.com/rooootdev/mond) for the Gestalt editor behavior integrated into this fork
