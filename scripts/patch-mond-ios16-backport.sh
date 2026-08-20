#!/usr/bin/env bash
set -euo pipefail

GEN="ThirdParty/mond-current/Generated/Mond"

python3 - "$GEN" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_required(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"iOS 16 backport contract changed: missing pattern in {path}: {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")

# Observation.framework / @Observable require iOS 17. Keep the same observable
# model semantics with Combine, which is available on iOS 16.
helper = root / "helpers_posterboard_tendies.swift"
replace_required(helper, "import Observation", "import Combine")
replace_required(helper, "@Observable\n@MainActor\nfinal class MondCurrentTendiesVM {", "@MainActor\nfinal class MondCurrentTendiesVM: ObservableObject {")
for name in ("wallpapers", "query", "loading", "error_msg"):
    replace_required(helper, f"    var {name}", f"    @Published var {name}")

# Backport the Tendies UI from iOS-17 conveniences to equivalent iOS-16 SwiftUI.
view = root / "views_tweaks_posterboard_TendiesView.swift"
replace_required(view, "@State private var vm = MondCurrentTendiesVM()", "@StateObject private var vm = MondCurrentTendiesVM()")
replace_required(view, ".topBarTrailing", ".navigationBarTrailing")
replace_required(
    view,
    '''ContentUnavailableView {
                        Label("Couldn't Load tendies", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task {
                                await vm.retry()
                            }
                        }
                    }''',
    '''VStack(spacing: 12) {
                        Label("Couldn't Load tendies", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task {
                                await vm.retry()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()'''
)
replace_required(
    view,
    "ContentUnavailableView.search",
    '''VStack(spacing: 8) {
                    Label("No Results", systemImage: "magnifyingglass")
                        .font(.headline)
                    Text("No wallpapers match your search.")
                        .foregroundStyle(.secondary)
                }
                .padding()'''
)
replace_required(
    view,
    '''ContentUnavailableView("Preview Unavailable", systemImage: "photo", description: Text("The wallpaper preview couldn't be loaded."))''',
    '''VStack(spacing: 8) {
                            Label("Preview Unavailable", systemImage: "photo")
                                .font(.headline)
                            Text("The wallpaper preview couldn't be loaded.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()'''
)

# The two-argument onChange closure is iOS 17. Both Settings and the CacheExtra
# editor only need the new value (or no values), so the iOS 16 overload is exact.
settings = root / "views_app_SettingsView.swift"
replace_required(settings, ".onChange(of: ka_on) { _, enabled in", ".onChange(of: ka_on) { enabled in")
gestalt = root / "views_tweaks_GestaltView.swift"
replace_required(gestalt, ".onChange(of: type) { _, _ in", ".onChange(of: type) { _ in")

# Santander uses iOS-17-only empty-state and top-bar placement conveniences.
# Preserve the same states/actions using primitives available on iOS 16.
santander = root / "views_tweaks_SantanderView.swift"
replace_required(santander, ".topBarTrailing", ".navigationBarTrailing")
replace_required(
    santander,
    '''ContentUnavailableView(empty_state_message, systemImage: "folder")''',
    '''VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(empty_state_message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()'''
)
replace_required(
    santander,
    '''ContentUnavailableView(failure_text("Failed to render image"), systemImage: "photo")''',
    '''VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(failure_text("Failed to render image"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()'''
)

# PosterBoard's descriptor-store generation differs by major OS version.
poster = root / "helpers_posterboard_poster.swift"
replace_required(
    poster,
    '    static let ext_version = "61"',
    '''    static var ext_version: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 ? "61" : "59"
    }'''
)

checks = {
    helper: ["ObservableObject", "@Published var wallpapers"],
    view: ["@StateObject private var vm", ".navigationBarTrailing", "No Results"],
    settings: [".onChange(of: ka_on) { enabled in"],
    gestalt: [".onChange(of: type) { _ in"],
    santander: [".navigationBarTrailing", "Text(empty_state_message)", 'failure_text("Failed to render image")'],
    poster: ['majorVersion >= 17 ? "61" : "59"'],
}
for path, needles in checks.items():
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"iOS 16 backport verification failed: {needle!r} missing from {path}")

for forbidden, paths in {
    "import Observation": (helper,),
    "@Observable": (helper,),
    "ContentUnavailableView": (view, santander),
    ".topBarTrailing": (view, santander),
    ".onChange(of: ka_on) { _,": (settings,),
    ".onChange(of: type) { _,": (gestalt,),
}.items():
    for path in paths:
        if forbidden in path.read_text(encoding="utf-8"):
            raise SystemExit(f"iOS 17-only API remains after backport: {forbidden} in {path}")

print("Mond 2.2 iOS 16 UI/PosterBoard/Santander backport applied")
PY
