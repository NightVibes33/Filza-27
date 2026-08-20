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

# Observation.framework / @Observable and @State ownership are iOS 17-era.
# Keep the exact model behavior while using Combine's iOS 13+ ObservableObject API.
helper = root / "helpers_posterboard_tendies.swift"
replace_required(helper, "import Observation", "import Combine")
replace_required(helper, "@Observable\n@MainActor\nfinal class MondCurrentTendiesVM {", "@MainActor\nfinal class MondCurrentTendiesVM: ObservableObject {")
for name in ("wallpapers", "query", "loading", "error_msg"):
    replace_required(helper, f"    var {name}", f"    @Published var {name}")

view = root / "views_tweaks_posterboard_TendiesView.swift"
replace_required(view, "@State private var vm = MondCurrentTendiesVM()", "@StateObject private var vm = MondCurrentTendiesVM()")
replace_required(view, ".topBarTrailing", ".navigationBarTrailing")
replace_required(
    view,
    '''MondCurrentContentUnavailableView {\n                        Label("Couldn't Load tendies", systemImage: "wifi.exclamationmark")\n                    } description: {\n                        Text(error)\n                    } actions: {\n                        Button("Try Again") {\n                            Task {\n                                await vm.retry()\n                            }\n                        }\n                    }''',
    '''VStack(spacing: 12) {\n                        Label("Couldn't Load tendies", systemImage: "wifi.exclamationmark")\n                            .font(.headline)\n                        Text(error)\n                            .foregroundStyle(.secondary)\n                            .multilineTextAlignment(.center)\n                        Button("Try Again") {\n                            Task {\n                                await vm.retry()\n                            }\n                        }\n                    }\n                    .frame(maxWidth: .infinity, maxHeight: .infinity)\n                    .padding()'''
)
replace_required(
    view,
    "MondCurrentContentUnavailableView.search",
    '''VStack(spacing: 8) {\n                    Label("No Results", systemImage: "magnifyingglass")\n                        .font(.headline)\n                    Text("No wallpapers match your search.")\n                        .foregroundStyle(.secondary)\n                }\n                .padding()'''
)
replace_required(
    view,
    '''MondCurrentContentUnavailableView("Preview Unavailable", systemImage: "photo", description: Text("The wallpaper preview couldn't be loaded."))''',
    '''VStack(spacing: 8) {\n                            Label("Preview Unavailable", systemImage: "photo")\n                                .font(.headline)\n                            Text("The wallpaper preview couldn't be loaded.")\n                                .foregroundStyle(.secondary)\n                                .multilineTextAlignment(.center)\n                        }\n                        .frame(maxWidth: .infinity)\n                        .padding()'''
)

# SwiftUI's two-argument onChange closure was introduced after iOS 16.
settings = root / "views_app_SettingsView.swift"
replace_required(settings, ".onChange(of: ka_on) { _, enabled in", ".onChange(of: ka_on) { enabled in")

# PosterBoard uses store 59 on iOS 16 and store 61 on iOS 17+.
poster = root / "helpers_posterboard_poster.swift"
replace_required(
    poster,
    '    static let ext_version = "61"',
    '''    static var ext_version: String {\n        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 ? "61" : "59"\n    }'''
)

# Assert the generated copy now contains only iOS-16-compatible forms we rely on.
checks = {
    helper: ["ObservableObject", "@Published var wallpapers"],
    view: ["@StateObject private var vm", ".navigationBarTrailing", "No Results"],
    settings: [".onChange(of: ka_on) { enabled in"],
    poster: ['majorVersion >= 17 ? "61" : "59"'],
}
for path, needles in checks.items():
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"iOS 16 backport verification failed: {needle!r} missing from {path}")

for forbidden in ("import Observation", "@Observable", "ContentUnavailableView", ".topBarTrailing", ".onChange(of: ka_on) { _,"):
    for path in (helper, view, settings):
        if forbidden in path.read_text(encoding="utf-8"):
            raise SystemExit(f"iOS 17-only API remains after backport: {forbidden} in {path}")

print("Mond 2.2 iOS 16 UI/PosterBoard backport applied")
PY
