# 3105 source pin

The Apps Manager and Patches integration tracks
[`NightVibes33/3105`](https://github.com/NightVibes33/3105) commit
`438f3ccae6a436d0017185407bc286e55c357883`, which is the upstream
[`YangJiiii/3105`](https://github.com/YangJiiii/3105) 1.0 release commit.

The Filza repository keeps the previous vendored 3105 tree as a rollback
baseline. `scripts/stage-3105-v1.sh` downloads the immutable pinned commit at
build time and overlays only the files changed by upstream 1.0 before Swift
compilation. The staged 1.0 update includes full file operations (preview,
share, copy, move, paste and ZIP creation), `.3105` imports from Files and
secure HTTPS import routes, uncapped patch projects, Cleaner size sorting and
bulk selection, and updated localization.

The complete upstream SwiftUI workspace is compiled into Filza: Home, Files,
Patches, Cleaner, Wallpapers, Settings, Logs, file operations, portable `.3105`
package handling, Keychain storage, patch transactions, backup/restore, secure
wallpaper-package extraction, and native app metadata helpers.

Filza intentionally retains only the embedding adaptations that cannot be taken
verbatim from the standalone app:

- the upstream `@main` application declaration is not compiled because Filza
  owns the UIApplication lifecycle;
- `ThreeOneOSFiveContentView(initialTab:)` preserves Filza's direct Home / Apps
  Manager / Patches entry points while also carrying 1.0's external-import tab
  routing;
- `ThreeOneOSFiveSettingsView` and the root content type are namespaced to
  coexist with ByeTunes in the same Swift module;
- `Filza3105Host.swift` supplies `AppState`, `PatchDraftCoordinator`, and the
  1.0 `FileOperationCoordinator`, plus the persistent Close control;
- `Filza3105Bridge.m` maps `.3105` documents and `threeoneosfive://` imports
  into the embedded Patches workspace instead of requiring 3105 to own `@main`;
- resource lookup targets `Filza3105.bundle`, and diagnostics are also copied
  to Filza's log;
- ContainerManager access continues to reuse Filza's retained leases.

The upstream GPLv3 license and third-party notices remain preserved here.
