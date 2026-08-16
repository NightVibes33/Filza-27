#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105"
UPSTREAM_OWNER="NightVibes33"
UPSTREAM_REPO="3105"
UPSTREAM_COMMIT="90ab4dd35823d58de10e6b8b78236e0e7e1ad32b"
UPSTREAM_VERSION="1.0.1"
ARCHIVE_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_COMMIT}"

for path in "$ROOT" "$ROOT/Sources" "$ROOT/Resources/Filza3105.bundle"; do
  test -d "$path" || { echo "Missing 3105 integration path: $path" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-3105-v101.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 "$ARCHIVE_URL" -o "$TMP/3105.tar.gz"
tar -xzf "$TMP/3105.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name '3105-*' -print -quit)"
test -n "$SRC" || { echo "Could not locate extracted 3105 source tree" >&2; exit 1; }
UPSTREAM="$SRC/ThreeOneOSFive"

# 1.0.1 introduced these source units. Fail closed if the pinned source is not
# the release we expect instead of silently building a partial 3105 workspace.
for required in \
  helpers/AppTabNavigationState.swift \
  helpers/FileOperationCoordinator.swift \
  helpers/PatchWorkspaceService.swift \
  helpers/ZIPArchiveExtractor.swift \
  helpers/ZIPArchiveWriter.swift \
  views/FilesTabControls.swift \
  views/FilesTabSwitcherView.swift \
  views/FileBrowserView.swift \
  views/PatchProjectsView.swift \
  ContentView.swift \
  views/SettingsView.swift \
  Info.plist; do
  test -f "$UPSTREAM/$required" || { echo "Missing upstream 3105 1.0.1 file: $required" >&2; exit 1; }
done

copy_source() {
  local relative="$1"
  local destination="$2"
  test -f "$UPSTREAM/$relative" || { echo "Missing upstream 3105 file: $relative" >&2; exit 1; }
  cp "$UPSTREAM/$relative" "$ROOT/Sources/$destination"
}

# Union of the files needed to move the vendored rollback baseline through the
# 1.0 release and then through every 1.0.1 functional change. The standalone
# App.swift remains intentionally excluded because Filza owns UIApplication.
copy_source helpers/AppIconHelper.m AppIconHelper.m
copy_source helpers/AppTabNavigationState.swift AppTabNavigationState.swift
copy_source helpers/CleanerCatalog.swift CleanerCatalog.swift
copy_source helpers/ContainerBrowserLogic.swift ContainerBrowserLogic.swift
copy_source helpers/ContainerStore.swift ContainerStore.swift
copy_source helpers/DevicePatchService.swift DevicePatchService.swift
copy_source helpers/FileManagerService.swift FileManagerService.swift
copy_source helpers/FileOperationCoordinator.swift FileOperationCoordinator.swift
copy_source helpers/FileReplacementService.swift FileReplacementService.swift
copy_source helpers/PatchDraftCoordinator.swift PatchDraftCoordinator.swift
copy_source helpers/PatchDraftService.swift PatchDraftService.swift
copy_source helpers/PatchPackageCodec.swift PatchPackageCodec.swift
copy_source helpers/PatchProjectLibrary.swift PatchProjectLibrary.swift
copy_source helpers/PatchProjectModels.swift PatchProjectModels.swift
copy_source helpers/PatchProjectStore.swift PatchProjectStore.swift
copy_source helpers/PatchTransaction.swift PatchTransaction.swift
copy_source helpers/PatchWorkspaceService.swift PatchWorkspaceService.swift
copy_source helpers/SupportPolicy.swift SupportPolicy.swift
copy_source helpers/ZIPArchiveExtractor.swift ZIPArchiveExtractor.swift
copy_source helpers/ZIPArchiveWriter.swift ZIPArchiveWriter.swift
copy_source views/AppDataBrowserView.swift AppDataBrowserView.swift
copy_source views/CleanerView.swift CleanerView.swift
copy_source views/DesignSystem.swift DesignSystem.swift
copy_source views/FileBrowserView.swift FileBrowserView.swift
copy_source views/FilesTabControls.swift FilesTabControls.swift
copy_source views/FilesTabSwitcherView.swift FilesTabSwitcherView.swift
copy_source views/FolderPatchSelectionView.swift FolderPatchSelectionView.swift
copy_source views/LogView.swift LogView.swift
copy_source views/PatchProjectEditorView.swift PatchProjectEditorView.swift
copy_source views/PatchProjectsView.swift PatchProjectsView.swift
copy_source views/WallpaperLabView.swift WallpaperLabView.swift

# ContentView and SettingsView are real upstream 1.0.1 views with only the
# minimal namespace/lifecycle adaptations needed to coexist inside Filza's one
# Swift module. Keep Filza's direct initial-tab entry points while preserving
# upstream responsive navigation, FilesTabSession and feature toggles.
copy_source ContentView.swift ThreeOneOSFiveContentView.swift
copy_source views/SettingsView.swift ThreeOneOSFiveSettingsView.swift

python3 - "$ROOT/Sources/ThreeOneOSFiveContentView.swift" "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift" <<'PY'
from pathlib import Path
import sys

content_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
content = content_path.read_text(encoding="utf-8")
settings = settings_path.read_text(encoding="utf-8")

replacements = [
    ("struct ContentView: View {", "struct ThreeOneOSFiveContentView: View {"),
    ("    init() {", "    init(initialTab requestedInitialTab: Int = 0) {"),
    ("        } else {\n            initialTab = 0\n        }", "        } else {\n            initialTab = requestedInitialTab\n        }"),
    ("        _tabNavigation = State(initialValue: AppTabNavigationState())", "        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: requestedInitialTab))"),
    (".sheet(isPresented: $showSettings) { SettingsView() }", ".sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }"),
]
for old, new in replacements:
    if old not in content:
        raise SystemExit(f"3105 ContentView adaptation anchor changed: {old}")
    content = content.replace(old, new, 1)

if "struct SettingsView: View {" not in settings:
    raise SystemExit("3105 SettingsView adaptation anchor changed")
settings = settings.replace(
    "struct SettingsView: View {",
    "struct ThreeOneOSFiveSettingsView: View {",
    1,
)

content_path.write_text(content, encoding="utf-8")
settings_path.write_text(settings, encoding="utf-8")
PY

for lang in en vi zh-Hans; do
  test -f "$UPSTREAM/$lang.lproj/Localizable.strings"
  mkdir -p "$ROOT/Resources/Filza3105.bundle/$lang.lproj"
  cp "$UPSTREAM/$lang.lproj/Localizable.strings" \
     "$ROOT/Resources/Filza3105.bundle/$lang.lproj/Localizable.strings"
done

# Deterministic metadata merge into the host IPA. This must report the actual
# upstream release, not Filza's own 4.11 app version.
cp "$UPSTREAM/Info.plist" "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist"

# 1.0 + 1.0.1 source-contract checks.
grep -Fq 'FileOperationCoordinator' "$ROOT/Sources/FileBrowserView.swift"
grep -Fq 'ZIPArchiveWriter' "$ROOT/Sources/FileManagerService.swift"
grep -Fq 'ZIPArchiveExtractor' "$ROOT/Sources/FileBrowserView.swift"
grep -Fq 'PatchWorkspaceService' "$ROOT/Sources/PatchProjectsView.swift"
grep -Fq 'FilesTabSession' "$ROOT/Sources/AppTabNavigationState.swift"
grep -Fq 'FilesTabSwitcherView' "$ROOT/Sources/FilesTabControls.swift"
grep -Fq 'FeatureVisibility' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'NavigationSplitView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'ThreeOneOSFiveSettingsView()' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'struct ThreeOneOSFiveSettingsView: View' "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift"
grep -Fq 'settings.developer_public_beta_build' "$ROOT/Resources/Filza3105.bundle/en.lproj/Localizable.strings"
grep -Fq '"browser.tabs"' "$ROOT/Resources/Filza3105.bundle/en.lproj/Localizable.strings"
grep -Fq '"browser.extract"' "$ROOT/Resources/Filza3105.bundle/en.lproj/Localizable.strings"

plutil -lint "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist" >/dev/null
test "$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION"
test "$(plutil -extract AppReleaseDisplayVersion raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION"

echo "Staged complete 3105 ${UPSTREAM_VERSION} from ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_COMMIT}"
