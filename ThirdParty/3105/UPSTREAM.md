# 3105 source pin

The Apps Manager and Patches integration is imported from
[`NightVibes33/3105`](https://github.com/NightVibes33/3105) commit
`1da66f733a7ad6bb5c9e1d078e89cfbb02faec72`.

The complete upstream SwiftUI workspace is compiled into FilzaSlop: Home,
Files, Patches, Cleaner, Wallpapers, Settings, Logs, file operations, portable
`.3105` package handling, Keychain storage, patch transactions, backup/restore,
secure wallpaper-package extraction, and native app metadata helpers.

The standalone upstream `@main` declaration is intentionally not compiled
because Filza owns the UIApplication lifecycle. `AppState.swift` preserves its
state object, `ThreeOneOSFiveContentView(initialTab:)` adds only an embed
entry-tab parameter, and the upstream root/Settings types and source filenames
are namespaced to coexist with ByeTunes in the same Swift module. Resource lookup targets
`Filza3105.bundle`, and diagnostics are also copied to FilzaSlop's log.
ContainerManager access reuses FilzaSlop's retained leases.
The upstream GPLv3 license and third-party notices are preserved here.
