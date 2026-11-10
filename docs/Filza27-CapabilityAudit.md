# Filza 27: complete integration and runtime evidence ledger

Target: feature/erozzion-airlift-ios18-27 on top of main. This ledger lists the full app, not just the latest bug. A green source/build CI result **is not** a pass for iPhone 16/iOS 27.0.1 runtime or sandbox privileges.

| Area | Retained implementation | Runtime validation still required |
|---|---|---|
| Original Filza browser and file actions | Tweak.m, original toolbar and file navigation | Browse, create, rename, ZIP, import, preview, local filesystem |
| Apps Manager 3105 | Original AppDataBrowserView + patches for Prepare/Decrypt, sort, Airlift metadata | Icons, complete list, installed bundle access, prepare/export, extension fidelity |
| Cleaner | Original list and delete allowlist, own-sandbox and authorized-root resolution | Measure actual caches of authorized apps, clean and remeasure safely |
| Wallpapers | Original 3105 Wallpaper Lab + optional Erosion writer | Write permission, recovery, rollback and actual PosterBoard result |
| Bad_query / MCM | Existing main sources and container activation | OS-build-specific capabilities; Apple-owned MHA identity is not provided by SideStore |
| Worse_query | Pinned upstream + provisioned dedicated App Group bridge | SideStore group actually granted; verified cache restoration and target open |
| Airlift | Pinned Erosion folder reader and native Filza staged folder integration | Original remote folder restored exactly; recovery incident must be resolved externally |
| IPA preparation | Local repackager, explicit opt-in remote preparation | Full Payload, binary/resources/extensions, FairPlay status; not just a ZIP |
| IPA decryption | In-process FairPlay research backend | Working permissions and actual decrypted Mach-O verification |
| NFCARD | Integrated iOS app + pinned Rust FFI | Wallet features, on-device RP record and tunnel |
| Pairing | Filza-owned shared RP settings and existing NFCARD source | Both on-device and file-based pairing, consumers use same valid record |
| ByeTunes | Embedded source and shared pairing | Actual songs, lyrics, metadata, downloading/embedding, on-device network |
| Mond / Gestalt | Embedded Mond 2.2 and main toolbar entry | Capabilities, safe edits, persistence and rollback |
| CoreMedia / system paths | Read-only CoreMedia bridge, main file browser | Path enumeration and read-only enforcement |
| SSH / SFTP | WolfSSH + Filza settings | Connection and transfer from another device |
| WebDAV | GCDWebServer integration | Real file operations over LAN |
| App ID / SideStore | Custom ID, ad-hoc request entitlements; no Sharing.appex | Actual SideStore provisioning and signed App Group, no 9400 |
| LiveContainer | Existing compatibility route | Behavior within its different host and sandbox |

## Confirmed issues and mitigation in this branch

1. Main's Cleaner shell and categories were restored in prior commits. A matching UI does not make previously inaccessible caches readable. Empty results now explicitly mean **no accessible caches verified**, not that installed apps lack caches. Logging distinguishes catalog candidates from cache-positive accessible roots.
2. IPA Prepare was silently falling back to a paired Airlift folder transaction after ordinary local access failed. It must not risk moving another app's directory without a separate explicit decision. Normal Prepare is local-only; a separate context action warns and checks the persisted safety stop.
3. Airlift's original folder reader had a restoration stop, but remote file/folder writes and remote deletions previously omitted that stop. All three remote mutation APIs now refuse while the incident is unresolved.
4. The pinned Erosion Rust backend returns explicit restoreConfirmed/restoreHandoffCompleted/restoreWarning. An unverified original path is not a successful or recoverable export. Do not clear the stop flag, reopen the impacted app, or erase recovery staging based solely on this repository.
5. The standard SideStore-signed custom bundle ID cannot legitimately inherit Apple-owned MobileHouseArrest identity. No source patch can promise all-app cache access from an ordinary signing profile.

## Acceptance rules

A shippable claim requires: (a) main behavior parity inspected for the named screen, (b) source safety tests pass, (c) ARM64 build and IPA metadata pass, and (d) relevant real-device behavior is independently reproduced. Passes of (a)–(c) **cannot be labeled** an exploit-runtime success. Device logs and actual folder or IPA output are needed for (d). Never replace unavailable cache sizes with invented 0 B values or auto-clear a restore safety incident.
