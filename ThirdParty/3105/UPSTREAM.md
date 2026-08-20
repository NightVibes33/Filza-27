# 3105 source pin

The embedded Apps Manager / Patches workspace tracks the official upstream
[`YangJiiii/3105`](https://github.com/YangJiiii/3105) **1.1.1** release at commit
`f1b81047a01a1817c7fb17e6938929eef108f1aa`.

`scripts/stage-3105-v1.sh` downloads that immutable 1.1.1 revision directly at
build time. The script name is retained for build compatibility; there is no
second overlay stage.

## Embedded 1.1.1 feature set

The Filza integration stages the current upstream workspace units that belong to
the embedded app, including:

- current Home / Files / Patches / Cleaner / Wallpapers workspace;
- the 1.1.1 Files/Patches interaction state;
- iOS 17.0–17.7.x and iOS 18.0–18.7.1 support-policy/backend updates;
- the existing iOS 26.0–26.6.1 and verified iOS 27 beta support policy;
- Patch Workspace v2, encrypted `.3105` packages, and legacy v1 decoding;
- safer patch transactions and restore journaling;
- ZIP extraction/creation with path, link, CRC, and space checks;
- multiple independent Files tabs with preserved navigation state;
- responsive iPad/landscape navigation with `NavigationSplitView`;
- Cleaner and Wallpaper feature visibility controls;
- current app/container discovery, metadata, settings, logs, and localization;
- the upstream 1.1.1 revisions of the kernel/sandbox backend files already
  represented by Filza's existing build graph.

Filza keeps its separately pinned global `bad_query` implementation rather than
adding a second copy from 3105.

## Filza embedding boundary

3105 is embedded as a child tool; it does not own the Filza process. The build
therefore keeps only the adaptations required for that boundary:

- upstream `@main ThreeOneOSFiveApp` / `WindowGroup` is not compiled;
- `AppState` is mirrored in `ThirdParty/3105/Sources/AppState.swift` so the 1.1.1
  support/kernel state machine works without taking over Filza's lifecycle;
- `KernelExploit.swift` preserves the upstream 1.1.1 coordinator behavior while
  binding Filza's already-built C symbols for the mixed Theos target;
- upstream `ContentView` is renamed deterministically to
  `ThreeOneOSFiveContentView` and accepts Filza's direct Home / Apps Manager /
  Patches initial route;
- upstream `SettingsView` is renamed to `ThreeOneOSFiveSettingsView` and keeps
  Filza's shared pairing section;
- app icons retain 3105/LaunchServices fallback and can be upgraded through
  Filza's shared ByeTunes SpringBoardServices connection;
- `.3105` document/custom-URL imports are routed by `Filza3105Bridge.m`;
- resources resolve through `Filza3105.bundle`;
- ContainerManager access continues to reuse Filza's retained leases.

Standalone process/window hooks are intentionally excluded from the host app.
The standalone `AntiDetection.m` process-wide `fork()` override and root-window
attribution gesture are not installed into Filza, so they cannot alter Filza,
SSH, ByeTunes, Mond, or other host behavior outside the 3105 view.

## Shared embedded UI

3105 is the canonical presentation style for third-party tools inside Filza 27.
`FilzaEmbeddedPanel.swift` owns the persistent material **Close** bar, divider,
large `.pageSheet`, visible grabber, and dismissal behavior. Presented 3105,
Mond, and ByeTunes use this same source component while keeping their own
internal SwiftUI screens and features.

This shared presentation layer applies only to embedded third-party apps. It
does not restyle or replace Filza's own navigation or file-browser UI.

The staging script verifies the 1.1.1 metadata and key embedding contracts,
including the support-state integration, shared pairing/icon adapter, canonical
embedded panel, and exclusion of standalone-global hooks before compilation.

The upstream GPLv3 license and third-party notices remain preserved.
