#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105"
UPSTREAM_OWNER="YangJiiii"
UPSTREAM_REPO="3105"
UPSTREAM_COMMIT="f1b81047a01a1817c7fb17e6938929eef108f1aa"
UPSTREAM_VERSION="1.1.1"
ARCHIVE_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_COMMIT}"

for path in "$ROOT" "$ROOT/Sources" "$ROOT/Resources/Filza3105.bundle"; do
  test -d "$path" || { echo "Missing 3105 integration path: $path" >&2; exit 1; }
done

test -f "$ROOT/Sources/AppState.swift" || { echo "Missing Filza embedded 3105 AppState adapter" >&2; exit 1; }
test -f "$ROOT/Sources/KernelExploit.swift" || { echo "Missing Filza embedded 3105 KernelExploit adapter" >&2; exit 1; }
test -f "$ROOT/Sources/FilzaEmbeddedPanel.swift" || { echo "Missing canonical embedded panel" >&2; exit 1; }
test -f "$ROOT/Sources/FilzaSharedPairingSupport.swift" || { echo "Missing Filza shared pairing support" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/filza-3105-v111.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 2 "$ARCHIVE_URL" -o "$TMP/3105.tar.gz"
tar -xzf "$TMP/3105.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -type d -name '3105-*' -print -quit)"
test -n "$SRC" || { echo "Could not locate extracted 3105 source tree" >&2; exit 1; }
UPSTREAM="$SRC/ThreeOneOSFive"

for required in \
  helpers/AppTabNavigationState.swift \
  helpers/ContainerStore.swift \
  helpers/DevicePatchService.swift \
  helpers/KernelExploit.swift \
  helpers/PatchProjectStore.swift \
  helpers/SupportPolicy.swift \
  helpers/Utils.swift \
  views/LogView.swift \
  views/PatchProjectsView.swift \
  ContentView.swift \
  views/SettingsView.swift \
  kexploit/kexploit_opa334.m \
  kexploit/offsets.m \
  kexploit/sandbox_escape.m \
  Info.plist; do
  test -f "$UPSTREAM/$required" || { echo "Missing upstream 3105 1.1.1 file: $required" >&2; exit 1; }
done

copy_source() {
  local relative="$1"
  local destination="$2"
  test -f "$UPSTREAM/$relative" || { echo "Missing upstream 3105 file: $relative" >&2; exit 1; }
  cp "$UPSTREAM/$relative" "$ROOT/Sources/$destination"
}

# Stage the complete source units already supported by the Filza embedding.
# AppState/KernelExploit remain small Filza adapters because upstream owns them
# from App.swift / its bridging header, while Filza owns UIApplication and the
# mixed Theos module. Standalone window hooks (onboarding/attribution and the
# process-wide fork override) are deliberately not installed into Filza.
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
copy_source helpers/Utils.swift Utils.swift
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
copy_source ContentView.swift ThreeOneOSFiveContentView.swift
copy_source views/SettingsView.swift ThreeOneOSFiveSettingsView.swift

# 1.1.1 updates the kernel backend used for the newly verified iOS 17/18 range.
# These files are already part of Filza's existing build graph, so stage the
# pinned upstream revisions in-place without adding a second implementation.
cp "$UPSTREAM/kexploit/kexploit_opa334.h" kexploit/kexploit_opa334.h
cp "$UPSTREAM/kexploit/kexploit_opa334.m" kexploit/kexploit_opa334.m
cp "$UPSTREAM/kexploit/offsets.m" kexploit/offsets.m
cp "$UPSTREAM/kexploit/sandbox_escape.h" sandbox_escape.h
cp "$UPSTREAM/kexploit/sandbox_escape.m" sandbox_escape.m

python3 - \
  "$ROOT/Sources/ThreeOneOSFiveContentView.swift" \
  "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift" \
  "$ROOT/Sources/AppDataBrowserView.swift" \
  "$ROOT/Sources/AppIconHelper.m" <<'PY'
from pathlib import Path
import sys

content_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
browser_path = Path(sys.argv[3])
icon_path = Path(sys.argv[4])

content = content_path.read_text(encoding="utf-8")
settings = settings_path.read_text(encoding="utf-8")
browser = browser_path.read_text(encoding="utf-8")
icon = icon_path.read_text(encoding="utf-8")

# Preserve direct Filza routes into 3105 while keeping upstream 1.1.1's layout.
replacements = [
    ("struct ContentView: View {", "struct ThreeOneOSFiveContentView: View {"),
    ("    init() {", "    init(initialTab requestedInitialTab: Int = 0) {"),
    ("        } else {\n            initialTab = 0\n        }", "        } else {\n            initialTab = requestedInitialTab\n        }"),
    ("        _tabNavigation = State(initialValue: AppTabNavigationState())", "        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: requestedInitialTab))"),
    (".sheet(isPresented: $showSettings) { SettingsView() }", ".sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }"),
]
for old, new in replacements:
    if old not in content:
        raise SystemExit(f"3105 1.1.1 ContentView adaptation anchor changed: {old}")
    content = content.replace(old, new, 1)
content_path.write_text(content, encoding="utf-8")

if "struct SettingsView: View {" not in settings:
    raise SystemExit("3105 1.1.1 SettingsView adaptation anchor changed")
settings = settings.replace("struct SettingsView: View {", "struct ThreeOneOSFiveSettingsView: View {", 1)
device_section = '''                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\\(AppInfo.osVersion) (\\(AppInfo.osBuild))")
                }
'''
if device_section not in settings:
    raise SystemExit("3105 1.1.1 Settings device section anchor changed")
settings = settings.replace(device_section, device_section + '''
                Filza3105PairingSettingsSection()
''', 1)
settings_path.write_text(settings, encoding="utf-8")

# Keep Filza's shared ByeTunes pairing path for enhanced SpringBoard icons. The
# normal 3105 icon is still shown immediately; the shared service only upgrades it.
old_guard = "            guard resolvedIcon == nil, !didRequestIcon else { return }\n"
new_guard = "            guard !didRequestIcon else { return }\n"
if old_guard not in browser:
    raise SystemExit("3105 1.1.1 BrowserAppIcon request guard anchor changed")
browser = browser.replace(old_guard, new_guard, 1)
old_icon_loader = '''            DispatchQueue.global(qos: .utility).async {
                let icon = iconForBundleID(bundleID)
                DispatchQueue.main.async {
                    resolvedIcon = icon
                }
            }
'''
new_icon_loader = '''            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.resolvedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
'''
if old_icon_loader not in browser:
    raise SystemExit("3105 1.1.1 BrowserAppIcon loader anchor changed")
browser = browser.replace(old_icon_loader, new_icon_loader, 1)
browser_path.write_text(browser, encoding="utf-8")

# Add only the Filza shared SpringBoardServices bridge to upstream AppIconHelper.
if "filzaSpringBoardIconForBundleIDRSD" in icon:
    raise SystemExit("3105 SpringBoard icon bridge unexpectedly already staged")
icon += r'''

#pragma mark - Filza shared paired SpringBoard icon service

static UIImage *FilzaSpringBoardImageFromClient(
    struct SpringBoardServicesClientHandle *client,
    NSString *bundleID
) {
    if (!client || bundleID.length == 0) return nil;

    void *pngData = NULL;
    size_t dataLen = 0;
    struct IdeviceFfiError *error = springboard_services_get_icon(
        client,
        bundleID.UTF8String,
        &pngData,
        &dataLen
    );
    if (error) {
        const char *message = error->message ? error->message : "unknown error";
        NSLog(@"[Filza3105Icons] SpringBoard icon failed for %@: %s", bundleID, message);
        idevice_error_free(error);
        if (pngData) idevice_data_free((uint8_t *)pngData, dataLen);
        return nil;
    }

    if (!pngData || dataLen == 0) {
        if (pngData) idevice_data_free((uint8_t *)pngData, dataLen);
        return nil;
    }

    NSData *data = [NSData dataWithBytes:pngData length:dataLen];
    idevice_data_free((uint8_t *)pngData, dataLen);
    return [UIImage imageWithData:data];
}

UIImage *filzaSpringBoardIconForBundleIDRSD(
    struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake,
    NSString *bundleID
) {
    if (!adapter || !handshake || bundleID.length == 0) return nil;
    struct SpringBoardServicesClientHandle *client = NULL;
    struct IdeviceFfiError *error = springboard_services_connect_rsd(adapter, handshake, &client);
    if (error) {
        idevice_error_free(error);
        return nil;
    }
    if (!client) return nil;
    UIImage *image = FilzaSpringBoardImageFromClient(client, bundleID);
    springboard_services_free(client);
    return image;
}

UIImage *filzaSpringBoardIconForBundleIDProvider(
    struct IdeviceProviderHandle *provider,
    NSString *bundleID
) {
    if (!provider || bundleID.length == 0) return nil;
    struct SpringBoardServicesClientHandle *client = NULL;
    struct IdeviceFfiError *error = springboard_services_connect(provider, &client);
    if (error) {
        idevice_error_free(error);
        return nil;
    }
    if (!client) return nil;
    UIImage *image = FilzaSpringBoardImageFromClient(client, bundleID);
    springboard_services_free(client);
    return image;
}
'''
icon_path.write_text(icon, encoding="utf-8")
PY

for lang in en vi zh-Hans; do
  test -f "$UPSTREAM/$lang.lproj/Localizable.strings" || {
    echo "3105 1.1.1 localization missing: $lang" >&2
    exit 1
  }
  mkdir -p "$ROOT/Resources/Filza3105.bundle/$lang.lproj"
  cp "$UPSTREAM/$lang.lproj/Localizable.strings" "$ROOT/Resources/Filza3105.bundle/$lang.lproj/Localizable.strings"
done

cp "$UPSTREAM/Info.plist" "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist"

assert_contains() {
  local needle="$1"
  local path="$2"
  local label="$3"
  grep -Fq "$needle" "$path" || {
    echo "3105 1.1.1 contract failed: $label ($needle) missing from $path" >&2
    exit 1
  }
}

assert_contains 'ThreeOneOSFiveContentView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'embedded ContentView namespace'
assert_contains 'ThreeOneOSFiveSettingsView()' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" 'embedded Settings route'
assert_contains 'kernelExploitApplicable' "$ROOT/Sources/ThreeOneOSFiveContentView.swift" '1.1.1 kernel status UI'
assert_contains 'verifiedIOS17Range' "$ROOT/Sources/SupportPolicy.swift" 'iOS 17 support range'
assert_contains 'verifiedIOS18Range' "$ROOT/Sources/SupportPolicy.swift" 'iOS 18 support range'
assert_contains 'KernelExploit.requiresSandboxEscape' "$ROOT/Sources/ContainerStore.swift" '1.1.1 container fallback routing'
assert_contains 'Filza3105PairingSettingsSection()' "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift" 'shared pairing settings'
assert_contains 'FilzaSharedPairingSupport.resolvedIcon' "$ROOT/Sources/AppDataBrowserView.swift" 'shared SpringBoard icon resolver'
assert_contains 'filzaSpringBoardIconForBundleIDRSD' "$ROOT/Sources/AppIconHelper.m" 'RSD SpringBoard icon bridge'
assert_contains 'func runKernelExploitIfNeeded()' "$ROOT/Sources/AppState.swift" 'embedded 1.1.1 AppState adapter'
assert_contains 'enum KernelExploit' "$ROOT/Sources/KernelExploit.swift" 'embedded 1.1.1 KernelExploit adapter'
assert_contains 'FilzaEmbeddedPanel' "$ROOT/Sources/FilzaEmbeddedPanel.swift" 'canonical embedded UI panel'
assert_contains 'kexploit_opa334' kexploit/kexploit_opa334.m '1.1.1 kernel backend'
assert_contains 'sandbox_escape' sandbox_escape.m '1.1.1 sandbox backend'
assert_contains '"browser.tabs"' "$ROOT/Resources/Filza3105.bundle/en.lproj/Localizable.strings" 'Files tab localization'

plutil -lint "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist" >/dev/null || {
  echo "3105 1.1.1 upstream Info.plist failed plutil validation" >&2
  exit 1
}

test "$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION" || {
  echo "3105 upstream CFBundleShortVersionString is not $UPSTREAM_VERSION" >&2
  exit 1
}
test "$(plutil -extract AppReleaseDisplayVersion raw -o - "$ROOT/Resources/Filza3105.bundle/UpstreamAppInfo.plist")" = "$UPSTREAM_VERSION" || {
  echo "3105 upstream AppReleaseDisplayVersion is not $UPSTREAM_VERSION" >&2
  exit 1
}

# Host safety: standalone 3105 owns its own WindowGroup, attribution window
# gesture and process-wide fork override. Those are not appropriate inside
# Filza's process and are intentionally excluded from the embedded source graph.
! grep -R -Fq 'pid_t fork(void)' "$ROOT/Sources"
! grep -R -Fq 'displayIdentityAttribution' "$ROOT/Sources"

echo "Staged embedded 3105 ${UPSTREAM_VERSION} from ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_COMMIT} with Filza-scoped host adapters"
