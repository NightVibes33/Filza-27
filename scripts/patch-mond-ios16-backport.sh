#!/usr/bin/env bash
set -euo pipefail

GEN="ThirdParty/mond-current/Generated/Mond"

python3 - "$GEN" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def replace_required(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"iOS 16 backport contract changed: missing pattern in {path}: {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")

# Observation.framework and @Observable are iOS 17-era. Preserve the model
# behavior with Combine's ObservableObject/@Published API, available on iOS 16.
helper = root / "helpers_posterboard_tendies.swift"
replace_required(helper, "import Observation", "import Combine")
replace_required(helper, "@Observable\n@MainActor\nfinal class MondCurrentTendiesVM {", "@MainActor\nfinal class MondCurrentTendiesVM: ObservableObject {")
for name in ("wallpapers", "query", "loading", "error_msg"):
    replace_required(helper, f"    var {name}", f"    @Published var {name}")

# Tendies' data/UI is valid on iOS 16; only a few presentation conveniences are
# iOS 17 APIs. Backport those while retaining the same async loading/import flow.
view = root / "views_tweaks_posterboard_TendiesView.swift"
replace_required(view, "@State private var vm = MondCurrentTendiesVM()", "@StateObject private var vm = MondCurrentTendiesVM()")
replace_required(view, ".topBarTrailing", ".navigationBarTrailing")

text = view.read_text(encoding="utf-8")n
PY
