# 3105 source pin

The embedded Apps Manager / Patches workspace tracks upstream
[`YangJiiii/3105`](https://github.com/YangJiiii/3105) **1.1.1** commit
`f1b81047a01a1817c7fb17e6938929eef108f1aa`.

The build keeps the known-good 1.0.1 staged baseline, then applies
`scripts/stage-3105-v111-overlay.sh` as an explicit immutable 1.1.1 overlay. The
overlay restages the current workspace sources, localization, app metadata and
the updated existing kexploit/sandbox backend units before compilation. It does
not replace Filza's separately pinned global `bad_query` implementation.

The embedded 1.1.1 integration includes:

- the current Home / Files / Patches / Cleaner / Wallpapers workspace;
- 1.1.1 Files/Patch interaction behavior;
- iOS 17.0–17.7.x and iOS 18.0–18.7.1 support-policy/kernel-path updates from upstream;
- the existing iOS 26.0–26.6.1 and verified iOS 27 beta support policy;
- Patch Workspace v2, encrypted `.3105` packages and legacy v1 decoding;
- safer patch transactions and restore journaling;
- ZIP extraction/creation with path, link, CRC and space checks;
- multiple independent Files tabs with preserved navigation state;
- responsive iPad/landscape navigation with `NavigationSplitView`;
- Cleaner and Wallpaper feature visibility controls;
- updated app/container discovery and metadata behavior;
- updated localization and 1.1.1 app metadata.

Filza intentionally keeps only the embedding adaptations required because 3105
is not the process owner here:

- upstream `@main ThreeOneOSFiveApp` / `WindowGroup` is not compiled;
- `AppState` is mirrored in `ThirdParty/3105/Sources/AppState.swift` so the 1.1.1
  support/kernel state machine works without taking over Filza's lifecycle;
- `KernelExploit.swift` keeps upstream 1.1.1 behavior but binds the already-built
  C symbols directly for the mixed Theos target instead of relying on 3105's
  standalone Xcode bridging header;
- upstream `ContentView` is renamed deterministically to
  `ThreeOneOSFiveContentView` and accepts Filza's direct Home / Apps Manager /
  Patches initial route;
- upstream `SettingsView` is renamed to `ThreeOneOSFiveSettingsView` and retains
  Filza's shared pairing section;
- app icons prefer Filza's shared paired SpringBoardServices resolver and retain
  upstream local icon fallback behavior;
- `.3105` document/custom-URL imports are routed by `Filza3105Bridge.m`;
- resources resolve through `Filza3105.bundle`;
- ContainerManager access continues to reuse Filza's retained leases.

## Shared embedded UI

3105 is the canonical presentation style for embedded tools in Filza 27.
`FilzaEmbeddedPanel.swift` implements the same persistent material Close bar,
divider, large page-sheet detent and visible grabber used by the 3105 host.
Presented ByeTunes and Mond routes use this same component so all three embedded
apps have a consistent exit/navigation container while preserving their own
internal SwiftUI views.

The upstream GPLv3 license and third-party notices remain preserved.
