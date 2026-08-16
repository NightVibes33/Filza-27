# 3105 source pin

The Apps Manager and Patches integration tracks
[`NightVibes33/3105`](https://github.com/NightVibes33/3105) commit
`90ab4dd35823d58de10e6b8b78236e0e7e1ad32b`, which is the upstream
[`YangJiiii/3105`](https://github.com/YangJiiii/3105) 1.0.1 release commit.

`scripts/stage-3105-v1.sh` downloads that immutable revision at build time and
stages the full set of source changes needed to move the vendored rollback
baseline through 1.0 and 1.0.1. New 1.0.1 source units are registered in the
Filza source graph before the staging hook runs, so they are compiled rather
than merely copied into the checkout.

The 1.0.1 integration includes:

- Patch Workspace v2 under the app Documents/Patches workspace;
- safer patch transactions and restore journaling for pre-existing, newly
  created, and patch-created files/directories;
- legacy v1 `.3105` package decoding alongside encrypted v2 workspaces;
- ZIP extraction with path, symbolic-link, CRC, and available-space checks;
- multiple independent Files tabs with preserved navigation state;
- responsive iPad/landscape navigation with `NavigationSplitView`;
- Home visibility toggles for Cleaner and Wallpapers;
- updated iOS 27 developer/public-beta labels and localization;
- the existing file operations, ZIP creation, Files/HTTPS patch imports,
  Cleaner, Wallpaper Lab, Keychain package handling, and app-container tools.

The complete upstream SwiftUI workspace is compiled into Filza: Home, Files,
Patches, Cleaner, Wallpapers, Settings, Logs, file operations, portable `.3105`
package handling, Keychain storage, patch transactions, backup/restore, secure
wallpaper-package extraction, and native app metadata helpers.

Filza intentionally retains only the embedding adaptations that cannot be taken
verbatim from the standalone app:

- the upstream `@main` application declaration is not compiled because Filza
  owns the UIApplication lifecycle;
- upstream `ContentView` is staged directly and deterministically renamed to
  `ThreeOneOSFiveContentView`; its initializer is extended only to preserve
  Filza's direct Home / Apps Manager / Patches entry points;
- upstream `SettingsView` is staged directly and renamed to
  `ThreeOneOSFiveSettingsView` so it can coexist with ByeTunes in one Swift
  module;
- `Filza3105Host.swift` supplies `AppState`, `PatchDraftCoordinator`, and
  `FileOperationCoordinator`, plus the persistent Close control;
- `Filza3105Bridge.m` maps `.3105` documents and `threeoneosfive://` imports
  into the embedded Patches workspace instead of requiring 3105 to own `@main`;
- resource lookup targets `Filza3105.bundle`, and diagnostics are also copied
  to Filza's log;
- ContainerManager access continues to reuse Filza's retained leases.

The staging script verifies the 1.0.1 metadata, responsive root, Patch Workspace,
Files tabs, ZIP extraction, and localization markers before compilation.

The upstream GPLv3 license and third-party notices remain preserved here.
