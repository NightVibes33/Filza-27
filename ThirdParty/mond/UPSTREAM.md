# Mond 2.0 integration provenance

The embedded Mond source is pinned to the exact upstream 2.0 commit:

- Repository: `rooootdev/mond`
- Commit: `87b38b2726160c6d1cfacbbfa834a2572d7ca333`
- Commit message: `mond 2.0` / `bug fixes, new features`
- Upstream deployment target: iOS 17.0
- PartyUI: `830eaac8ebf8a4cbcec08d49e8746033574d1903` (`1.2.0`)
- ZIPFoundation: `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (`0.9.20`)

The 2.0 source graph embedded by `scripts/stage-mond-current.sh` includes:

- `mond/exploit/cmg.swift`
- `mond/exploit/unsbx.swift`
- `mond/exploit/bad_query/bad_query.c`
- `mond/exploit/bad_query/bad_query.h`
- `mond/helpers/keepalive.swift`
- `mond/helpers/mg.swift`
- `mond/helpers/posterboard/poster.swift`
- `mond/helpers/posterboard/tendies.swift`
- `mond/helpers/sbx.swift`
- `mond/helpers/utils.swift`
- `mond/views/app/ContentView.swift`
- `mond/views/app/LogView.swift`
- `mond/views/app/SettingsView.swift`
- `mond/views/tweaks/GestaltView.swift`
- `mond/views/tweaks/SantanderView.swift`
- `mond/views/tweaks/posterboard/PosterView.swift`
- `mond/views/tweaks/posterboard/TendiesView.swift`

`mond/mond.swift` is also retained in the untouched staged upstream snapshot for lifecycle provenance. Filza already owns the process `UIApplication`, so `@main struct mond: App` cannot be compiled as a second app entry point. `FilzaMondCurrentHost.swift` reproduces that 2.0 lifecycle inside Filza: stdout capture, defaults registration, Keep Alive startup, document-picker swizzle, URL import handling, support warning, automatic `grant_all(state:)` on appearance, and respring overlay.

## No Filza behavior patches

Mond 2.0 is not patched with the previous Filza-specific token-status changes, extra iOS 27 MobileGestalt key section, hard-coded accent-color replacement, manual-exploit-only lifecycle, or other Mond UI/behavior modifications.

The only generated-source transformations are mechanical integration requirements:

1. remove `import PartyUI` / `import ZIPFoundation` because their exact pinned sources are compiled into the same Filza Swift module,
2. namespace colliding Swift/C symbols,
3. host the upstream app lifecycle from Filza's existing `UIApplication`.

`ThirdParty/mond-current/Upstream` is recreated at build time as an untouched copy of the complete Mond 2.0 `mond/` source tree before those mechanical transformations are applied to `Generated/`.
