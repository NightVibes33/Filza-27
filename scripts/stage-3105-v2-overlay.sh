#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105"
UPSTREAM_OWNER="YangJiiii"
UPSTREAM_REPO="3105"
UPSTREAM_COMMIT="4a15d823b711bc0639de1f3fd2c764b5982d9245"
UPSTREAM_VERSION="2.0"
UPSTREAM_BUILD="8"
ARCHIVE_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_COMMIT}"

for path in "$ROOT" "$ROOT/Sources" "$ROOT/Resources/Filza3105.bundle"; do
  test -d "$path" || { echo "Missing 3105 integration path: $path" >&2; exit 1; }
done

# The 1.1.1 pass runs first and establishes the Filza-owned adapters. This
# overlay intentionally replaces only source units changed by upstream 2.0.
# App.swift, OnboardingView.swift, standalone attribution/window hooks and the
# kernel/lifecycle adapters remain owned by Filza.
test -f "$ROOT/Sources/AppState.swift" || { echo "Missing Filza 3105 AppState adapter" >&2; exit 1; }
test -f "$ROOT/Sources/KernelExploit.swift" || { echo "Missing Filza 3105 KernelExploit adapter" >&2; exit 1; }
test -f "$ROOT/Sources/FilzaEmbeddedPanel.swift" || { echo "Missing Filza embedded panel" >&2; exit 1; }
test -f "$ROOT/Sources/FilzaSharedPairingSupport.swift" || { echo "Missing shared pairing support" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-3105-v20.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 "$ARCHIVE_URL" -o "$TMP/3105.tar.gz"
tar -xzf "$TMP/3105.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name '3105-*' -print -quit)"
test -n "$SRC" || { echo "Could not locate extracted 3105 2.0 source tree" >&2; exit 1; }
UPSTREAM="$SRC/ThreeOneOSFive"

copy_source() {
  local relative="$1"
  local destination="$2"
  test -f "$UPSTREAM/$relative" || { echo "Missing upstream 3105 2.0 file: $relative" >&2; exit 1; }
  cp "$UPSTREAM/$relative" "$ROOT/Sources/$destination"
}

# Exact upstream delta from f1b8104 (1.1.1) through 4a15d82 (2.0 + latest
# repository-install result hotfix), excluding standalone lifecycle/onboarding.
copy_source helpers/AppTabNavigationState.swift AppTabNavigationState.swift
copy_source helpers/ContainerStore.swift ContainerStore.swift
copy_source helpers/DevicePatchService.swift DevicePatchService.swift
copy_source helpers/FileBrowserMetadata.swift FileBrowserMetadata.swift
copy_source helpers/PackageRepositoryModels.swift PackageRepositoryModels.swift
copy_source helpers/PackageRepositoryStore.swift PackageRepositoryStore.swift
copy_source helpers/PatchPackageCodec.swift PatchPackageCodec.swift
copy_source helpers/PatchProjectLibrary.swift PatchProjectLibrary.swift
copy_source helpers/PatchProjectModels.swift PatchProjectModels.swift
copy_source helpers/PatchProjectStore.swift PatchProjectStore.swift
copy_source helpers/PatchTransaction.swift PatchTransaction.swift
copy_source helpers/PatchWorkspaceService.swift PatchWorkspaceService.swift
copy_source helpers/RepositoryPresentationSupport.swift RepositoryPresentationSupport.swift
copy_source helpers/WallpaperInstaller.swift WallpaperInstaller.swift
copy_source helpers/WallpaperLabService.swift WallpaperLabService.swift
copy_source views/AppDataBrowserView.swift AppDataBrowserView.swift
copy_source views/DesignSystem.swift DesignSystem.swift
copy_source views/FileBrowserView.swift FileBrowserView.swift
copy_source views/PatchProjectEditorView.swift PatchProjectEditorView.swift
copy_source views/PatchProjectsView.swift PatchProjectsView.swift
copy_source views/RepositoryHomeView.swift RepositoryHomeView.swift
copy_source views/RepositoryMarketplaceView.swift RepositoryMarketplaceView.swift
copy_source views/RepositorySourcesView.swift RepositorySourcesView.swift
copy_source views/SettingsView.swift ThreeOneOSFiveSettingsView.swift
copy_source views/WallpaperLabView.swift WallpaperLabView.swift
copy_source ContentView.swift ThreeOneOSFiveContentView.swift

python3 - \
  "$ROOT/Sources/ThreeOneOSFiveContentView.swift" \
  "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift" \
  "$ROOT/Sources/AppDataBrowserView.swift" \
  "$ROOT/Sources/AppTabNavigationState.swift" <<'PY'
from pathlib import Path
import sys

content_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
browser_path = Path(sys.argv[3])
navigation_path = Path(sys.argv[4])

content = content_path.read_text(encoding="utf-8")
settings = settings_path.read_text(encoding="utf-8")
browser = browser_path.read_text(encoding="utf-8")
navigation = navigation_path.read_text(encoding="utf-8")

# Namespace the upstream roots so they coexist with Filza and preserve direct
# routes from Filza quick actions into semantic 3105 2.0 sections.
replacements = [
    ("struct ContentView: View {", "struct ThreeOneOSFiveContentView: View {"),
    ("    init() {", "    init(initialTab requestedInitialTab: Int = AppSection.home.rawValue) {"),
    ("        } else {\n            initialTab = 0\n        }", "        } else {\n            initialTab = requestedInitialTab\n        }"),
    ("        _tabNavigation = State(initialValue: AppTabNavigationState())", "        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: requestedInitialTab))"),
    (".sheet(isPresented: $showSettings) { SettingsView() }", ".sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }"),
]
for old, new in replacements:
    if old not in content:
        raise SystemExit(f"3105 2.0 ContentView adaptation anchor changed: {old}")
    content = content.replace(old, new, 1)
content_path.write_text(content, encoding="utf-8")

if "struct SettingsView: View {" not in settings:
    raise SystemExit("3105 2.0 SettingsView adaptation anchor changed")
settings = settings.replace("struct SettingsView: View {", "struct ThreeOneOSFiveSettingsView: View {", 1)
device_section = '''                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\\(AppInfo.osVersion) (\\(AppInfo.osBuild))")
                }
'''
if device_section not in settings:
    raise SystemExit("3105 2.0 Settings device-section anchor changed")
settings = settings.replace(device_section, device_section + '''

                Filza3105PairingSettingsSection()
''', 1)
settings_path.write_text(settings, encoding="utf-8")

# Preserve Filza's shared ByeTunes/3105 pairing path for SpringBoard icons.
old_guard = "            guard resolvedIcon == nil, !didRequestIcon else { return }\n"
new_guard = "            guard !didRequestIcon else { return }\n"
if old_guard not in browser:
    raise SystemExit("3105 2.0 BrowserAppIcon request guard anchor changed")
browser = browser.replace(old_guard, new_guard, 1)
old_loader = '''            DispatchQueue.global(qos: .utility).async {
                let icon = iconForBundleID(bundleID)
                DispatchQueue.main.async {
                    resolvedIcon = icon
                }
            }
'''
new_loader = '''            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.resolvedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
'''
if old_loader not in browser:
    raise SystemExit("3105 2.0 BrowserAppIcon loader anchor changed")
browser = browser.replace(old_loader, new_loader, 1)
browser_path.write_text(browser, encoding="utf-8")

# Standalone 3105 hides Files behind Developer Mode. In Filza, Files is the
# Apps Manager route, so it must remain reachable regardless of that preference.
visibility = '''        case .files:
            return developerModeEnabled
'''
if visibility not in navigation:
    raise SystemExit("3105 2.0 Files visibility anchor changed")
navigation = navigation.replace(visibility, '''        case .files:
            return true
''', 1)
navigation_path.write_text(navigation, encoding="utf-8")
PY

for lang in en vi zh-Hans; do
  test -f "$UPSTREAM/$lang.lproj/Localizable.strings" || {
    echo "3105 2.0 localization missing: $lang" >&2
    exit 1
  }
  mkdir -p "$ROOT/Resources/Filza3105.bundle/$lang.lproj"
  cp "$UPSTREAM/$lang.lproj/Localizable.strings" "$ROOT/Resources/Filza3105.bundle/$lang.lproj/Localizable.strings"
done

# Upstream's project.pbxproj was bumped to marketing version 2.0/build 8, but
# its checked-in Info.plist still says 1.1.1/build 7. Preserve the plist shape
# and stamp the metadata that corresponds to the pinned 2.0 source revision.
cp "$UPSTREAM/Info.plist" "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist"
python3 - \
  "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist" \
  "$UPSTREAM_VERSION" \
  "$UPSTREAM_BUILD" <<'PY'
import plistlib
import sys

path, version, build = sys.argv[1:]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
info["CFBundleShortVersionString"] = version
info["AppReleaseDisplayVersion"] = version
info["CFBundleVersion"] = build
with open(path, "wb") as handle:
    plistlib.dump(info, handle, sort_keys=False)
PY

assert_contains() {
  local needle="$1"
  local path="$2"
  local label="$3"
  grep -Fq "$needle" "$path" || {
    echo "3105 2.0 contract failed: $label ($needle) missing from $path" >&2
    exit 1
  }
}

assert_contains 'ThreeOneOSFiveContentView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'embedded ContentView namespace'
assert_contains 'AppSection.installed.rawValue' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'installed/package route'
assert_contains 'RepositoryHomeView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'repository Home route'
assert_contains 'RepositorySourcesView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'repository Sources route'
assert_contains 'RepositorySearchView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'repository Search route'
assert_contains 'repositoryStorePresentation(repositoryStore, patchStore: patchStore)' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'latest repository install-result presentation'
assert_contains 'latestSchemaVersion = 3' "$ROOT/Sources/PatchPackageCodec.swift" 'patch schema v3'
assert_contains 'var author: String' "$ROOT/Sources/PatchProjectModels.swift" 'patch author metadata'
assert_contains 'var isPrivate: Bool' "$ROOT/Sources/PatchProjectModels.swift" 'private patch metadata'
assert_contains 'PackageRepositoryStore' "$ROOT/Sources/PackageRepositoryStore.swift" 'repository store'
assert_contains 'RepositoryPackage' "$ROOT/Sources/PackageRepositoryModels.swift" 'repository package models'
assert_contains 'PatchRestoreInspection' "$ROOT/Sources/DevicePatchService.swift" 'restore inspection'
assert_contains 'FileBrowserSortOrder' "$ROOT/Sources/FileBrowserMetadata.swift" 'file browser sorting metadata'
assert_contains 'Filza3105PairingSettingsSection()' "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift" 'shared pairing settings'
assert_contains 'FilzaSharedPairingSupport.resolvedIcon' "$ROOT/Sources/AppDataBrowserView.swift" 'shared SpringBoard icon resolver'
assert_contains 'case .files:' "$ROOT/Sources/AppTabNavigationState.swift" 'Files/Apps Manager section'
assert_contains 'return true' "$ROOT/Sources/AppTabNavigationState.swift" 'Filza always-visible Apps Manager route'

plutil -lint "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist" >/dev/null || {
  echo "3105 2.0 embedded Info.plist failed plutil validation" >&2
  exit 1
}
test "$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION" || {
  echo "3105 embedded CFBundleShortVersionString is not $UPSTREAM_VERSION" >&2
  exit 1
}
test "$(plutil -extract AppReleaseDisplayVersion raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION" || {
  echo "3105 embedded AppReleaseDisplayVersion is not $UPSTREAM_VERSION" >&2
  exit 1
}
test "$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_BUILD" || {
  echo "3105 embedded CFBundleVersion is not $UPSTREAM_BUILD" >&2
  exit 1
}

echo "Applied pinned upstream 3105 2.0 overlay at $UPSTREAM_COMMIT while preserving Filza adapters"
