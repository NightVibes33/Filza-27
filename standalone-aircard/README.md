# NFCARD migration source

The standalone AirCard work that was developed on this Filza-27 branch has been migrated to the dedicated **NFCARD** repository:

https://github.com/NightVibes33/NFCARD

This branch is retained as the migration/source-history reference. The dedicated NFCARD repository is now the canonical standalone project and should be used for future NFCARD development and builds.

## Synchronized state

- Filza-27 source branch: `temp/aircard-wallet-standalone`
- NFCARD migration head: `172101e48615341bebcdc62d599c5ee8530049ff`
- Upstream base: `Mak5er/AirCard-iOS`
- Pinned upstream commit: `097a058c984ffc33ccb697b9dfe8058be3e86244`
- App display name: `NFCARD`
- Bundle identifier: `com.nightvibes33.aircard`

## Migrated functionality

- Dark graphite + mint NFCARD Pairing and Wallet Cards UI.
- Local iPhone pairing and PIN flow.
- Persistent paired state with remove/re-pair.
- Real LocalDevVPN connection-state handling.
- Live Wallet card scanning.
- Photos/Files artwork selection.
- Card selection and artwork application.
- Embedded Card Library / Card Studio.
- Live Remote Pairing Bonjour port discovery.
- Prewarmed Library WebView to eliminate the old first-open hitch.
- User-facing pairing plist names, raw file sizes, network/IP diagnostics and pairing logs removed.
- Passcode and Wallpapers tabs remain intentionally excluded.

The dedicated NFCARD repository contains the reproducible build, CI, attribution, documentation and rolling IPA release pipeline. Filza-27 `main` is not modified by this standalone migration.
