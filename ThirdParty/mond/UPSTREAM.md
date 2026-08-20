# Mond 2.2 integration provenance

The embedded Mond source is pinned to the exact current upstream 2.2 tree used by this branch:

- Repository: `rooootdev/mond`
- Release line: `2.2`
- Commit: `3d91194716ad5f06afdf7e9037e6964e80a4ac29`
- Commit message: `Merge pull request #114 from hxhlb/fix-ios27` / `Fix iOS 27 region restrictions and MobileGestalt persistence`
- Upstream deployment target: iOS 17.0
- PartyUI: `830eaac8ebf8a4cbcec08d49e8746033574d1903` (`1.2.0`)
- ZIPFoundation: `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (`0.9.20`)

The 2.2 source graph embedded by `scripts/stage-mond-current.sh` plus `scripts/stage-mond-22-overlay.sh` includes:

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
- `mond/views/tweaks/mobilegestalt/GestaltView.swift`
- `mond/views/tweaks/mobilegestalt/CEView.swift`
- `mond/views/tweaks/SantanderView.swift`
- `mond/views/tweaks/posterboard/PosterView.swift`
- `mond/views/tweaks/posterboard/TendiesView.swift`

`mond/mond.swift` is retained in the untouched staged upstream snapshot for lifecycle provenance. Filza already owns the process `UIApplication`, so `@main struct mond: App` cannot be compiled as a second app entry point. `FilzaMondCurrentHost.swift` reproduces the Mond lifecycle inside Filza: stdout capture, the upstream `method = bad_query` and `atomic_write = true` defaults, Keep Alive startup, document-picker compatibility swizzle, URL import handling, support warning, shared `AppState`, automatic `grant_all(state:)` on appearance, and the respring overlay.

Mond 2.2 additions retained by the embedded build include:

- CacheExtra field browsing/editing via the new `CEView`,
- the `Persist after reboot` option,
- the `Ignore exploit failure` option,
- the current MobileGestalt persistence behavior,
- the corrected iOS 27 region keys/current region behavior,
- the 2.2 MobileGestalt tweak set and current upstream warning text.

## Integration transformations

`ThirdParty/mond-current/Upstream` is recreated at build time as an untouched copy of the complete pinned Mond `mond/` source tree. Only the generated embedded copy is adapted for coexistence inside Filza.

The transformations are deliberately narrow:

1. remove `import PartyUI` / `import ZIPFoundation` because their exact pinned sources are compiled into the same Filza Swift module,
2. namespace colliding Swift/C symbols without altering user-facing strings/comments,
3. supply Mond's exact accent color, defaults domain, and bundle identity from the Filza host,
4. host the upstream app lifecycle from Filza's existing `UIApplication`,
5. make the new 2.2 CacheExtra editor's `AppState` environment dependency explicit in the generated copy because `CEView` calls `state.respring()` while the pinned upstream file currently omits its own `@EnvironmentObject` declaration.

The old Filza-specific Mond patches are not reintroduced: there is no custom token-status UI, no injected iOS 27 Gestalt-key section, and no alternate manual-exploit lifecycle. The pinned upstream snapshot is preserved for auditing and the build fails if its expected source graph or key 2.2 behaviors drift.

Filza's own package/application version remains independently anchored and is not changed by the Mond integration.
