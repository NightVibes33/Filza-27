# Mond 2.1 integration provenance

The embedded Mond source is pinned to the exact upstream 2.1 release commit:

- Repository: `rooootdev/mond`
- Release: `2.1`
- Commit: `500d76082f0ca021ddd591c05d129ebbc26c20df`
- Commit message: `fix tweaks not applying`
- Upstream deployment target: iOS 17.0
- PartyUI: `830eaac8ebf8a4cbcec08d49e8746033574d1903` (`1.2.0`)
- ZIPFoundation: `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (`0.9.20`)

The 2.1 source graph embedded by `scripts/stage-mond-current.sh` includes:

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

`mond/mond.swift` is also retained in the untouched staged upstream snapshot for lifecycle provenance. Filza already owns the process `UIApplication`, so `@main struct mond: App` cannot be compiled as a second app entry point. `FilzaMondCurrentHost.swift` reproduces the 2.1 lifecycle inside Filza: stdout capture, the upstream `method = bad_query` default, Keep Alive startup, document-picker swizzle, URL import handling, support warning, shared `AppState`, automatic `grant_all(state:)` on appearance, and respring overlay.

Mond 2.1's upstream tweak fix is retained unchanged, including the `CacheExtra` write path, safe MobileGestalt cache offsets, and CMG grant-state correction introduced by the 2.1 release line.

## No Filza behavior patches

Mond 2.1 is not patched with the previous Filza-specific token-status changes, extra iOS 27 MobileGestalt key section, hard-coded accent-color replacement, manual-exploit-only lifecycle, or other Mond UI/behavior modifications.

The only generated-source transformations are mechanical integration requirements:

1. remove `import PartyUI` / `import ZIPFoundation` because their exact pinned sources are compiled into the same Filza Swift module,
2. namespace colliding Swift/C symbols without altering strings/comments,
3. host the upstream app lifecycle from Filza's existing `UIApplication`.

`ThirdParty/mond-current/Upstream` is recreated at build time as an untouched copy of the complete Mond 2.1 `mond/` source tree before those mechanical transformations are applied to `Generated/`.

Filza's own package/application version remains independently anchored and is not changed by the Mond integration.
