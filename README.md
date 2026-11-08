# FilzaSlop / Filza-27

A jailed, sideloadable Filza fork combining Filza with app/container management, ByeTunes, Mond 2.2, WebDAV, SSH/SFTP, and the 3105 patch workspace.

[![Filza ByeTunes Upstream Release](https://img.shields.io/badge/release-ByeTunes%20Upstream-brightgreen)](https://github.com/NightVibes33/Filza-27/releases/tag/Filza-27-byetunes-upstream)

## Download

### [Download `Filza-27.ipa` — ByeTunes Upstream release](https://github.com/NightVibes33/Filza-27/releases/download/Filza-27-byetunes-upstream/Filza-27.ipa)

- Minimum deployment target: **iOS 17.0**.
- Current release: **`Filza-27-byetunes-upstream`**.\n- Release page: [`Filza-27-byetunes-upstream`](https://github.com/NightVibes33/Filza-27/releases/tag/Filza-27-byetunes-upstream)\n- IPA asset: [`Filza-27.ipa`](https://github.com/NightVibes33/Filza-27/releases/download/Filza-27-byetunes-upstream/Filza-27.ipa)\n
> **This is not a full jailbreak.** Filza-27 exposes only files and containers the app can actually access. It does not claim kernel read/write, unrestricted `/`, a root shell, an SPTM bypass, or a writable system volume.

## Included features

| Feature | Status | Notes |
| --- | --- | --- |
| Filza file browser | ✅ | Visibility still follows actual sandbox/access state |
| Apps Manager | ✅ 3105 1.1.1 | App/container details depend on available APIs/permissions |
| iOS 26 app discovery | ✅ | LaunchServices store candidates + direct MCM validation |
| Shared device pairing | ⚠️ Partial | ByeTunes and 3105 share one pairing state; selecting a pairing file works in ByeTunes but the embedded 3105 selector currently does not |
| Enhanced app icons | ✅ where supported | SpringBoardServices with LaunchServices fallback |
| `.3105` Patch Workspace v2 | ✅ | Portable projects, backup/restore, receipts/journals |
| 3105 IPA repackaging | ✅ | Repackages the installed app bundle without decrypting FairPlay |
| Music Library / ByeTunes | ✅ | Embedded ByeTunes integration |
| YouTube metadata provider | ✅ | Required solver resources packaged |
| Mond 2.2 UI/runtime | ✅ | Integrated directly into the iOS 17+ core |
| MobileGestalt editor | ✅ | Mond route |
| SiriAI on older devices | ✅ Included | iOS 27+ toggle writes `SiriMode` key `a3n5T9sFtlyQ74NEp9ESxg` to integer `2` |
| iPadOS Mode | ✅ Re-enabled | Mond's existing high-risk warning remains; the row is no longer hard-disabled by the iPhone model gate |
| CacheExtra Fields | ✅ | Current Mond 2.2 route |
| PosterBoard / Tendies | ✅ | Applying changes still depends on writable target access |
| HouseArrest / Santander | ✅ | Access remains OS/build-specific |
| WebDAV server | ⚠️ Runtime unverified | App-hosted listener builds successfully, but device behavior is currently unverified and likely broken |
| SSH/SFTP server | ⚠️ Runtime unverified | wolfSSH/SFTP builds successfully, but real device connections and background behavior are currently unverified and likely broken |
| Home Screen quick actions | ✅ Build verified | The packaged `apps-manager` shortcut normalizes to the embedded 3105 route; in-app Apps Manager uses the same 3105 presenter |
| Shared third-party panel | ✅ | 3105, Mond, presented ByeTunes; Filza browser UI unchanged |
| Full jailbreak / writable system volume | ❌ Not claimed | Outside this project's proven capabilities |

## Compatibility

The application and integrated runtime build with a minimum deployment target of **iOS 17.0**.

iOS **27.0.1** passes the app and ByeTunes pairing version checks. On iOS 27+, ByeTunes offers on-device code pairing and expects an RP pairing record for file import. Successful parsing of an imported record does not confirm that the device still trusts it. iOS 27.0.1 device testing remains unverified.

UI availability and filesystem-access capability are separate. Mond's `bad_query`, `cmg`, private APIs, 3105 backend paths, and cross-container write paths remain OS/build-specific. Filza-27 validates what access is actually available on the running device rather than treating the UI as proof of unrestricted access.

For iOS 27 research builds, useful `bad_query` behavior is associated with specific builds; do not infer unrestricted access merely because Mond loads.

### Experimental LiveContainer compatibility

> [!WARNING]
> LiveContainer compatibility is **experimental**. This mode does **not** provide MobileHouseArrest access to App Store apps or other apps installed by iOS. It exposes only guest apps and data stored inside the active LiveContainer environment.

The legacy MobileHouseArrest path requires the actual signed code identity `com.apple.mobile.MobileHouseArrest`. Standard re-signed installations and LiveContainer guests do not acquire that identity or its privileges; they use whatever other backends succeed on their OS/build.

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

1. Download `Filza-27.ipa` from the `Filza-27-byetunes-upstream` release using the link above.
2. Sideload it with your preferred signing method.
3. The unsigned build defaults to this normal application bundle ID:

```text
com.filza27.nigtvibes33
```

Sign with your own Apple ID/developer certificate. SideStore, AltStore and other signers may change this bundle ID to one accepted by your provisioning profile; Filza no longer requires a special identifier to start. The identity written into the actual code signature is authoritative.

**Capability routing:** MobileHouseArrest/MCM container activation is attempted only when the signed identity is genuinely `com.apple.mobile.MobileHouseArrest` and the OS exposes the required symbols. For a normal or re-signed bundle ID, Filza creates an app-sandbox file browser and retains Mond/`bad_query`, 3105/LaunchServices, NFCARD/Airlift pairing, ByeTunes and other available routes. Backend access depends on observed OS permission and exploit success, not the bundle ID. Changing the ID cannot bypass a patched `bad_query` or grant system-container access.

**Release note:** Existing published IPAs may still use the previous identity until a new build is verified and released. Installing under a different bundle ID produces a separate app container; back up files in the old installation first.

## Main tools

### Apps Manager / 3105

3105 discovers apps through its ContainerStore/MCM/LaunchServices pipeline. The pairing file is required for paired-device services such as SpringBoardServices icon upgrades and other live-device features, but it is not the sole source of the basic app catalog.

3105 and ByeTunes use the same shared pairing state and connection. The pairing-file picker currently works in ByeTunes but does not work from the embedded 3105 interface. Select the pairing file in ByeTunes instead; 3105 should then reuse that shared pairing file, so a failure to select it again inside 3105 is not itself a pairing failure.

The Home Screen long-press **Apps Manager** quick action normalizes the packaged `apps-manager` identifier to the embedded 3105 route. GitHub Actions build 307 verified the corrected identifier and compiled route in the generated arm64 IPA.

Apps Manager embeds **3105 1.1.1** from:

```text
YangJiiii/3105@f1b81047a01a1817c7fb17e6938929eef108f1aa
```

It includes app search, icon and disk-size recovery where available, container browsing, independent Files tabs, file preview, create/rename/import/replace/delete operations, ZIP creation/extraction, IPA repackaging support, and Patch Workspace handoff.

Because 3105 is embedded rather than process owner, Filza does not compile its standalone `@main` lifecycle or install standalone-global window/process hooks into the Filza host. See `ThirdParty/3105/UPSTREAM.md` for the embedding boundary.

### Music Library / ByeTunes

ByeTunes is embedded directly into Filza-27 and includes library browsing, downloads, queue persistence, backups, restore/repair tools, metadata editing, and multi-source metadata routing.

The integration retains the known working pre-v2.4 YouTubeKit metadata path as the first free YouTube provider. Required JavaScript solver resources are packaged inside the IPA.

LocalDevVPN connection uses the unchanged `RemotePairingDiscovery.swift` and Remote Pairing tunnel methods from `EduAlexxis/ByeTunes@c66b1923a537c957d3b90620824ff3eb19593b5d`: Bonjour port resolution, fallback port 49152, and the upstream device host `10.7.0.1`. Filza pauses automatic reconnection while its on-device pairing sheet is active.

### Mond 2.2 / Gestalt / PosterBoard

Available Mond routes include:

- MobileGestalt
- SiriAI on older devices (iOS 27+), with an info button explaining the `SiriMode = 2` override
- iPadOS Mode, re-enabled in Mond's Gestalt editor with its existing risk warning
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

The current public build is the [\`Filza-27-byetunes-upstream\` release](https://github.com/NightVibes33/Filza-27/releases/tag/Filza-27-byetunes-upstream), with the unsigned [\`Filza-27.ipa\` asset](https://github.com/NightVibes33/Filza-27/releases/download/Filza-27-byetunes-upstream/Filza-27.ipa).

The remaining CI workflows cover full-build diagnostics and the 3105/shared embedded UI source contract. Historical ByeTunes verifier, iOS 16, simulator-probe, and duplicate release workflows have been removed.

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
- [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query) (pinned GPLv3 source)
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

## worse_query native filesystem access (iOS 26–27)

The original forcequitOS/worse_query GPLv3 implementation is vendored,
unaltered, from commit bd41f874b3f4d28c4d61b51c7dfb98f0e8a5e9ec.
scripts/verify-worse-query.py verifies every upstream Git blob, including
LICENSE. This is not a wrapper that silently substitutes bad_query or Airlift.

- Filza's one native file browser keeps the existing folder action. Choose
  Open Direct to request a real upstream worse_query sandbox extension and
  navigate into that original directory, only after a genuine open succeeds.
  Read Folder remains the separately paired Airlift folder-export option.
- 3105 Apps Manager, Cleaner and Wallpaper Lab reuse the real shared MCM
  container resolver. When MCM is denied, worse_query tries a real container
  path supplied by LaunchServices or an actually discovered app data URL.
  A denied grant does not become a fabricated app, permission or cache size.
  Cleaner's original single app list and cache-limited deletion remain.
- All earlier bad_query routes remain. Airlift stays hidden behind the
  original UI, not as a new Filza app or another file browser.
- Worse_query does not claim access to /usr/libexec or system-volume writes;
  native read-only CoreMedia browsing is still a separate backend.

**App Group signing is now supported by a dedicated GitHub Actions workflow:**
[Sign Filza 27 with real App Group](.github/workflows/sign-filza27-appgroup.yml).
See [Signing/README-AppGroup.md](Signing/README-AppGroup.md) for the four
certificate/provisioning secrets and setup. The workflow verifies the Apple
Developer Team, registered app ID, the group in the provisioned profile,
and the group in the final signed code signature. It then produces a distinct
signed IPA artifact. The regular unsigned artifact remains available; when the four required Apple
Developer secrets are configured, the same ARM64 build also signs and uploads
a separate validated Filza-27-AppGroup-signed-arm64 artifact. Without a valid
matching Apple profile, the unsigned IPA cannot activate App Groups by itself.
If the user's signer strips or cannot provision the group, this backend
accurately reports unavailable and existing methods remain.

**Restoration safeguard:** Every invocation verifies that the dedicated App Group `Library/Caches` has been restored to a real, empty directory, even when the upstream query fails. If restoration is unconfirmed, Filza persists a safety stop and refuses further worse_query attempts. Recovery must be verified and performed explicitly; no automatic retry deletes unknown cache contents.

**Upstream safety requirement:** Worse_query temporarily replaces the caller's
App Group Library/Caches directory with a symlink. The Filza adapter uses
a dedicated disposable group and refuses to run against a populated or
symlinked cache. It also validates a consumed extension by opening the
original directory before reporting a successful grant. An outstanding
Airlift restoration safety stop disables new direct and remote reads until
device recovery. This is not a jailbreak, root grant, or proven
iOS 27.0.1 physical-device result.

## Research note

This repository includes compatibility and filesystem-access research for modern iOS. Those experiments should be treated as research features, not proof of unrestricted system access.

## Erosion backends in Filza's original browser and Apps Manager (iOS 18–27.0.1)

**Filza remains the only file browser.** No Erosion app, fifth toolbar
button, separate Airlift file-browser tab, or second file manager is shipped.

- **Filza → Device Storage → SYSTEM PATHS - READ-ONLY → CoreMedia →
  usr → libexec** uses the optional CoreMedia XPC bytestream reader.
  The existing native Filza directory UI opens genuine read-only local
  snapshots when CoreMedia can return the system bytes. Each directory is
  populated off the main thread and the same Filza folder refreshes when done.
  Its ACCESS STATUS.txt lists actual results and omissions. No general system
  filesystem capability or privilege escalation is implied; these are local
  copies, not writes to the original /usr/libexec.
- **3105 Apps Manager** keeps MCM, MobileHouseArrest, LaunchServices and
  older bad_query discovery. Airlift supplies optional InstallationProxy
  metadata and confirmed per-app snapshots when paired transport succeeds.
- **All-app Cleaner** retains its existing local cache/tmp cleaning logic;
  Airlift is an additional per-app path, not a Filza-only cleaner.
- **Wallpapers and other embedded modules** retain their supported Erosion
  transport functions where a real device transaction succeeds.
- **Filza → Device Storage → [Airlift] Snapshots** can contain staged
  snapshots from supported app-manager operations. These are local copies;
  edits do not sync back automatically.

All pairing is still managed centrally from Filza Settings → Device Pairing.
On-device pairing and importing a pairing file remain available.

The NFCARD integration now pins the newest NFCARD main revision
`16f8bfd20a88a474f59c2d6eda291164a1cc015f`; its existing Wallet,
card library and pairing screens remain intact. Erosion's Rust overlay is
pinned to `a8dc7e48b13e130e69c28269a43fc4a8b456952a` and is built
into the same AirliftFFI static library to avoid duplicate symbols.

**Compatibility:** The app's minimum supported deployment remains iOS 17
(with the requested support envelope of iOS 18 through 27.0.1). Available
capabilities are determined at runtime. The known `bad_query` builds retain
their existing routes. Later builds without `bad_query` can still enumerate
apps through a valid paired InstallationProxy session; remote reads and writes
are contingent on real device/OS support and can fail. None of the new code
claims unrestricted kernel access, sandbox escape, guaranteed write access,
or working FairPlay decryption.

**Safety and distribution:** Airlift folder reads perform device-side
staging/restoration transactions, not ordinary read-only filesystem opens.
An incomplete app-container restore is rejected with a recovery warning.
The imported Erosion upstream currently does not declare a license in its
GitHub repository: verify written permission or an applicable license before
redistributing binaries containing its code.

**Build:** `scripts/stage-nfcard.sh` stages the pinned NFCARD/AirCard
and Erosion source; `scripts/build-nfcard-ffi.sh` builds the single FFI.
`scripts/patch-3105-airlift.py` re-applies the Apps Manager metadata merge
after `stage-3105-v1.sh` replaces 3105's upstream sources.


### Apps Manager: long-press Prepare → Decrypt

Long-press an app in **Apps Manager** and select **Prepare**. Filza tries existing local/bad_query-repackaging first and then paired NFCARD/Airlift when an actual app bundle path is known. After successful staging and Mach-O inspection, long-press again for **Decrypt**, **Export prepared IPA**, or **Prepare again**. Preparation does not modify the installed app. Decrypt reports if the prepared executable is already unencrypted. FairPlay-encrypted binaries need a privileged runtime decryption backend not bundled in this build; Filza will not claim the encrypted IPA is decrypted.


### Integrated FairPlay backend — one Filza IPA

Apps Manager **long-press → Prepare → Decrypt** now calls the original in-process `FilzaFairPlayBackend` and `FilzaFairPlayRuntime.c`; no second FairPlayed app is installed and no unlicensed upstream source is copied. The existing local/bad_query and paired NFCARD/Airlift routes continue to prepare the IPA.

The optional decryptor attempts `mremap_encrypted` on the **original installed executable**, verifies page-in via `vm_read_overwrite`, checks the returned bytes are plausibly decrypted, and only writes verified plaintext to an isolated staging area. Full arm64 executable/framework/extension checks must pass before offering **Export decrypted IPA**. The original installed app is not modified.

**Important:** FairPlay can reject the original installed path even when Airlift successfully copies the app. On restricted iOS versions, including stock 27.0.1, this all-in-one route is unproven; it does not bypass the helper's pre-install embedding requirement. Errors are shown instead of falsely claiming decryption success. Physical device validation is required.


**3105 paired-app diagnostics:** Airlift now accepts both InstallationProxy
`/var/mobile/Containers/Data/Application/` and
`/var/containers/Data/Application/` path variants, and reports both raw and
accepted app/bundle counts in Filza Diagnostics. The existing local/MCM app
catalog is kept separate from paired discovery and the list updates with the
new result. An app path returned in metadata is not proof that the sandbox,
Airlift read, or patched `bad_query` can open that path.


### Erosion wiring: Apps Manager, Cleaner and Wallpapers

The 3105 Apps Manager preserves its local MCM/LaunchServices catalog and merges
Erosion's paired InstallationProxy metadata. A discovered app ID does not
imply a directly readable filesystem path; use **Browse via Airlift** to
attempt a real remote snapshot. Paired-device scan failures are shown rather
than silently being treated as empty local filesystems.

The 3105 **Cleaner** now has a separate **Erosion app containers** section,
listing actual metadata paths with a **Browse remote snapshot** action. Its
existing safe local Cache/tmp cleaning continues to remove only files in
containers that iOS actually grants Filza direct access to. **Erosion does not
supply a general system-cache deletion capability**, so these remote paths
are never counted as reclaimable bytes or silently deleted.

The 3105 **Wallpapers** panel adds a user-confirmed **Apply selected pack via
Erosion/Airlift** alternative when native MCM access is unavailable. The
original code stages validated .tendies descriptors, randomizes the IDs and
calls the pinned Erosion Airlift **folder-injection API** targeting the
InstallationProxy-discovered PosterBoard container. Every write result is
checked and partial success is reported. The generation-61 path depends on
the device's PosterBoard implementation; an unavailable path or failed
Airlift transaction is an error, not a successful installation. This remote
route does **not** create 3105's local rollback receipts; the confirmation
explains that limitation. No automatic PosterBoard preference overwrite or
respring is performed.

These routes depend on a functional NFCARD pairing record, LocalDevVPN and
actual iOS support. They do not make patched `bad_query` functional.


### Fix: Airlift shows unpaired despite shared on-device RP pairing

The iOS 27 NFCARD `PairingController.pairingFilePath()` checks the top-level
Documents directory. The ByeTunes/3105 shared pairing manager keeps its
validated RP record at `DeviceManager.shared.rpPairingFile` (normally under
`Documents/pairing file/rpPairingFile.plist`, or its app group when available).
This mismatch previously prevented InstallationProxy from even starting.

Filza's Airlift backend now reuses the shared RP record **in place**, falling
back to NFCARD's existing on-device pairing location. It does not export
pairing secrets, create a second record, or treat pairing availability as proof
of an active LocalDevVPN tunnel. `Runtime.log` records the selected pairing
**source label**, then the real InstallationProxy result or error (never the
record content). A missing record gives explicit pairing guidance.

3105's existing **top-right Refresh** triggers both 3105 and paired Airlift
scans. The duplicate bottom **Scan** button and obscuring bottom status inset
are removed. Airlift scan status now appears as a readable section in the app
list, above the installed applications. This is a source and build fix; actual
physical-device results still require testing on the installed build.


### Unified device pairing in native Filza 27 Settings

Filza's native Settings now provides one **DEVICE PAIRING** row, backed by
`FilzaUnifiedPairing.swift`. It has two fully functional options:
**Start on-device pairing** (existing RPPairing host and PIN flow) and
**Select pairing file** (the existing DeviceManager format validation/import).
Existing imported records remain in the canonical shared RP location; neither
the record content nor secret material is logged.

The pairing status and the separate LocalDevVPN transport state are shown
explicitly. On a pairing change, 3105's enhanced-icon cache is cleared, the
Airlift InstallationProxy catalog is rescanned, and NFCARD refreshes its path
and network status. NFCARD now consumes the validated shared RP file before
its legacy on-device Documents location. Its duplicate Pairing tab is hidden,
but its host code remains compiled. ByeTunes onboarding is nonblocking and
its Settings pairing action is replaced by guidance to native Filza Settings.
3105's embedded settings pairing importer is removed, leaving transport
and icon services as consumers.

**Filza is the file browser.** The duplicate Airlift file-browser sheet and
toolbar inside 3105 Apps Manager, the Cleaner remote-browser sheet, and the
extra 3105 bottom Scan button are removed. The original top-right 3105 refresh
remains. Paired InstallationProxy metadata appears as such, but a discovered
container is not treated as accessible without an actual read. Successfully
staged Airlift snapshots are available under Filza's native
`Device Storage/[Airlift] Snapshots` alias.


### Native Filza 27 snapshot integration

3105's existing installed-app list offers a confirmed **Stage snapshot in
Filza 27** action when paired Airlift identifies an app with no directly
accessible MCM path. If the real paired read and restoration succeeds, it saves
under **Filza 27 → Device Storage → [Airlift] Snapshots**. Filza itself remains
the only file browser; the separate Airlift transport panel no longer embeds
3105 FileBrowserView. Metadata-only paths never masquerade as sandbox grants.
The original 3105 top-right Refresh is retained, and no bottom Scan button or
second 3105 file-browser sheet is inserted.

The Erosion Airlift static-library cache is validated for both
`al_exploit_inject_folder` and `al_find_app_container`. An incomplete cached
runtime must be rebuilt before Wallpapers/PosterBoard integration is accepted.


### Cleaner for all installed apps (verified local + paired Airlift)

3105 Cleaner is an **installed-app cache cleaner**, not a Filza-only cleaner.
Its local scanner discovers apps through LaunchServices, MCM and the available
MobileHouseArrest candidates. The local app catalog no longer discards a
bundle ID after one denied MCM lookup: only a successfully readable cache is
marked resolved. When cleaning, it reuses the verified container instead of
blindly repeating MCM activation. Deletion remains restricted to each app's
`Library/Caches` and `tmp`; application documents, databases, keychains,
preferences and home folders are excluded.

After Filza's unified pairing connects, Cleaner also lists **all installed
apps returned by paired InstallationProxy**, including apps without a local
sandbox grant. Each app can explicitly request **Inspect app cache via
Airlift**: Erosion's actual folder reader creates a ZIP snapshot of that
app's `Library/Caches` and `tmp`, and Filza requires confirmed restore before
inspecting the archive. Archive entries are validated, not guessed from app
metadata. Only entries confirmed in a complete snapshot are eligible for an
additional destructive confirmation and **Clean verified Airlift cache**.
The remote removal uses Erosion's actual exact-path operation, stops on first
error, and logs the accepted count and **estimated** bytes; it never presents
transport success as verified reclaimed space. Failed, incomplete, oversized,
unsafe, or inaccessible snapshots disable remote cleaning until a fresh scan.

Airlift is an optional per-app fallback, not proof of universal filesystem
access on iOS 27.0.1. Protected app containers that iOS refuses remain clearly
unavailable. No automatic mass deletion or hidden background cleanup runs.


**Cleaner compatibility invariant:** the original main-branch Cleaner UI and
its API, LaunchServices, MCM/MobileHouseArrest, app-container resolution, and
existing iOS-version-specific direct-access paths remain unchanged in the
tracked 3105 source. The build overlays a verified per-app Airlift fallback
only after the original local Cleaner is staged. Local cache scanning and
deleting still use `LimitedCleanerService` with the original safe
`Library/Caches` and `tmp` allowlist; paired remote data is a separately
confirmed, explicitly selected option and is not mixed into local reclaimable
size calculations. CI now checks the legacy routes are present after staging
and applying the Airlift overlay.
