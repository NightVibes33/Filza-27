# mond integration provenance

The embedded mond workspace is adapted from:

- Repository: `rooootdev/mond`
- Branch inspected: `main`
- Pinned commit: `4a37bfca5cb4abb2c99891972365d872d700525e`
- Commit message: `Update ContentView.swift`

The current upstream root at that commit contains:

- `mond/views/App/ContentView.swift` — `mond` navigation root, Logs, MobileGestalt, PosterBoard, disabled HouseArrest, Settings toolbar
- `mond/views/App/LogView.swift` — live terminal-style output
- `mond/views/App/SettingsView.swift` — bad_query/cmg selector, Run Exploit, sandbox token, Keep Alive, Respring, credits
- `mond/views/Tweaks/GestaltView.swift` — MobileGestalt editor
- `mond/views/Tweaks/PosterView.swift` — PosterBoard UI
- `mond/views/Tweaks/SantanderView.swift` — HouseArrest work-in-progress UI

Filza remains the owning iOS application, so upstream's `@main struct mond: App` cannot be embedded verbatim. `MondFullRootHost.swift` adapts the current root/settings lifecycle into a `UIHostingController`, while the existing complete Gestalt implementation and Filza's validated PosterBoard workspace are used as the corresponding destinations. The visible navigation hierarchy and current upstream HouseArrest availability/footer are preserved.

Do not update this pin without comparing the upstream root/settings/tweak views and rebuilding the complete arm64 IPA.
