#!/usr/bin/env bash
set -euxo pipefail

PIN='4a15d823b711bc0639de1f3fd2c764b5982d9245'
ROOT='ThirdParty/3105'
UPSTREAM="$ROOT/UpstreamRepo/ThreeOneOSFive"
SOURCES="$ROOT/Sources"
RESOURCES="$ROOT/Resources/Filza3105.bundle"

test "$(cat "$ROOT/UPSTREAM_PIN")" = "$PIN"
test -f "$UPSTREAM/ContentView.swift"
test -f "$UPSTREAM/views/SettingsView.swift"
test -f "$UPSTREAM/helpers/PackageRepositoryStore.swift"

VERIFY_DIR="$(mktemp -d)"
git clone -q https://github.com/YangJiiii/3105.git "$VERIFY_DIR/3105"
git -C "$VERIFY_DIR/3105" checkout -q --detach "$PIN"
diff -qr --exclude='.git' "$VERIFY_DIR/3105" "$ROOT/UpstreamRepo"
rm -rf "$VERIFY_DIR"

git fetch origin main --quiet
rm -rf "$SOURCES" "$ROOT/Resources"
mkdir -p "$SOURCES" "$RESOURCES"

python3 - "$UPSTREAM" "$SOURCES" <<'PY'
from pathlib import Path
import shutil, sys
upstream = Path(sys.argv[1])
dest = Path(sys.argv[2])
seen = {}
for dirname in ('helpers', 'views', 'exploit'):
    root = upstream / dirname
    if not root.exists():
        continue
    for src in sorted(root.rglob('*.swift')):
        if src.name in {'KernelExploit.swift', 'SettingsView.swift'}:
            continue
        previous = seen.get(src.name)
        if previous and previous.read_bytes() != src.read_bytes():
            raise SystemExit(f'duplicate upstream Swift basename: {src.name}: {previous} vs {src}')
        seen[src.name] = src
        shutil.copy2(src, dest / src.name)
shutil.copy2(upstream / 'ContentView.swift', dest / 'ThreeOneOSFiveContentView.swift')
shutil.copy2(upstream / 'views' / 'SettingsView.swift', dest / 'ThreeOneOSFiveSettingsView.swift')
for name in ('AppIconHelper.m', 'AppIconHelper.h', 'wallpaper_zip.c', 'wallpaper_zip.h'):
    matches = list(upstream.rglob(name))
    if matches:
        shutil.copy2(matches[0], dest / name)
PY

for name in AppState.swift KernelExploit.swift FilzaEmbeddedPanel.swift FilzaSharedPairingSupport.swift FilzaAppIPAExporter.swift; do
  git show "origin/main:$ROOT/Sources/$name" > "$SOURCES/$name"
done
git show "origin/main:$ROOT/Sources/AppIconHelper.h" > "$SOURCES/AppIconHelper.h"

MAIN_ICON="$(mktemp)"
git show "origin/main:$ROOT/Sources/AppIconHelper.m" > "$MAIN_ICON"
python3 - "$SOURCES/AppIconHelper.m" "$MAIN_ICON" <<'PY'
from pathlib import Path
import sys
current = Path(sys.argv[1])
main = Path(sys.argv[2]).read_text(encoding='utf-8')
text = current.read_text(encoding='utf-8')
marker = '\n#pragma mark - Filza shared paired SpringBoard icon service\n'
if marker not in main:
    raise SystemExit('main Filza SpringBoard icon bridge marker missing')
bridge = marker + main.split(marker, 1)[1]
if marker in text:
    text = text.split(marker, 1)[0].rstrip() + '\n'
current.write_text(text.rstrip() + bridge, encoding='utf-8')
PY
rm -f "$MAIN_ICON"

find "$UPSTREAM" -maxdepth 1 -type d -name '*.lproj' -print0 | while IFS= read -r -d '' lang; do
  mkdir -p "$RESOURCES/$(basename "$lang")"
  cp "$lang/Localizable.strings" "$RESOURCES/$(basename "$lang")/Localizable.strings"
done
cp "$UPSTREAM/Info.plist" "$RESOURCES/UpstreamAppInfo.plist"
python3 - "$RESOURCES/UpstreamAppInfo.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    data = plistlib.load(f)
data['CFBundleShortVersionString'] = '2.0'
data['AppReleaseDisplayVersion'] = '2.0'
data['CFBundleVersion'] = '8'
data['AppReleaseBuildNumber'] = 8
with open(p, 'wb') as f:
    plistlib.dump(data, f)
PY

mkdir -p kexploit
for src in "$UPSTREAM"/kexploit/*; do
  test -f "$src" || continue
  case "$(basename "$src")" in
    sandbox_escape.h) cp "$src" sandbox_escape.h ;;
    sandbox_escape.m) cp "$src" sandbox_escape.m ;;
    *.h|*.m|*.c) cp "$src" "kexploit/$(basename "$src")" ;;
  esac
done

python3 - "$SOURCES/ThreeOneOSFiveContentView.swift" "$SOURCES/ThreeOneOSFiveSettingsView.swift" "$SOURCES/AppDataBrowserView.swift" "$SOURCES/Utils.swift" "$SOURCES/RepositoryPresentationSupport.swift" <<'PY'
from pathlib import Path
import sys
content_p, settings_p, browser_p, utils_p, repo_p = map(Path, sys.argv[1:])

content = content_p.read_text(encoding='utf-8')
if 'struct ContentView: View {' not in content:
    raise SystemExit('ContentView namespace anchor changed')
content = content.replace('struct ContentView: View {', 'struct ThreeOneOSFiveContentView: View {', 1)
anchor = '    @State private var tabNavigation: AppTabNavigationState\n'
if anchor not in content:
    raise SystemExit('ContentView tabNavigation anchor changed')
content = content.replace(anchor, '    private let forceFilesVisible: Bool\n' + anchor, 1)
if '    init() {\n' not in content:
    raise SystemExit('ContentView init anchor changed')
content = content.replace('    init() {\n', '    init(initialTab requestedInitialTab: Int = AppSection.home.rawValue) {\n        forceFilesVisible = requestedInitialTab == AppSection.files.rawValue\n', 1)
if '        } else {\n            initialTab = 0\n        }' not in content:
    raise SystemExit('ContentView simulator default anchor changed')
content = content.replace('        } else {\n            initialTab = 0\n        }', '        } else {\n            initialTab = requestedInitialTab\n        }', 1)
if '        _tabNavigation = State(initialValue: AppTabNavigationState())\n' not in content:
    raise SystemExit('ContentView device initializer anchor changed')
content = content.replace('        _tabNavigation = State(initialValue: AppTabNavigationState())\n', '        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: requestedInitialTab))\n', 1)
if '.sheet(isPresented: $showSettings) { SettingsView() }' not in content:
    raise SystemExit('ContentView Settings route anchor changed')
content = content.replace('.sheet(isPresented: $showSettings) { SettingsView() }', '.sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }', 1)
if 'FeatureVisibility(developerModeEnabled: developerModeActive)' not in content:
    raise SystemExit('ContentView FeatureVisibility anchor changed')
content = content.replace('FeatureVisibility(developerModeEnabled: developerModeActive)', 'FeatureVisibility(developerModeEnabled: developerModeActive || forceFilesVisible)', 1)
content_p.write_text(content, encoding='utf-8')

settings = settings_p.read_text(encoding='utf-8')
if 'struct SettingsView: View {' not in settings:
    raise SystemExit('SettingsView namespace anchor changed')
settings = settings.replace('struct SettingsView: View {', 'struct ThreeOneOSFiveSettingsView: View {', 1)
device = '''                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\\(AppInfo.osVersion) (\\(AppInfo.osBuild))")
                }
'''
if device not in settings:
    raise SystemExit('Settings device section anchor changed')
settings = settings.replace(device, device + '\n                Filza3105PairingSettingsSection()\n', 1)
settings_p.write_text(settings, encoding='utf-8')

browser = browser_p.read_text(encoding='utf-8')
utility = '''                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
'''
if utility not in browser:
    raise SystemExit('AppDataBrowser AppUtilityToolbar anchor changed')
browser = browser.replace(utility, '', 1)
toolbar_end = '''                }
            }
            .onAppear {
'''
utility_toolbar = '''                }
            }
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .onAppear {
'''
if toolbar_end not in browser:
    raise SystemExit('AppDataBrowser toolbar split anchor changed')
browser = browser.replace(toolbar_end, utility_toolbar, 1)
guard = '            guard resolvedIcon == nil, !didRequestIcon else { return }\n'
if guard not in browser:
    raise SystemExit('BrowserAppIcon request guard changed')
browser = browser.replace(guard, '            guard !didRequestIcon else { return }\n', 1)
loader = '''            DispatchQueue.global(qos: .utility).async {
                let icon = iconForBundleID(bundleID)
                DispatchQueue.main.async {
                    resolvedIcon = icon
                }
            }
'''
replacement = '''            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.resolvedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
'''
if loader not in browser:
    raise SystemExit('BrowserAppIcon loader changed')
browser_p.write_text(browser.replace(loader, replacement, 1), encoding='utf-8')

utils = utils_p.read_text(encoding='utf-8')
att = '''        // Validate display-identity attestation at first access; keeps
        // DisplayIdentity linked. Looks like a license/attestation check.
        _ = DisplayIdentityAttestationToken()
'''
if att in utils:
    utils = utils.replace(att, '', 1)
launch = '    static var launchAttestationToken: String { DisplayIdentityAttestationToken() }\n'
if launch in utils:
    utils = utils.replace(launch, '', 1)
marker = '\nenum AppUpdateChecker {\n'
if marker in utils:
    utils = utils[:utils.find(marker)].rstrip() + '\n'
utils_p.write_text(utils, encoding='utf-8')

repo = repo_p.read_text(encoding='utf-8')
cache = '''            decodedCache.setObject(
                image,
                forKey: cacheKey as NSString,
                cost: image.memoryCost
            )
'''
if cache in repo:
    repo = repo.replace(cache, '''            decodedCache.setObject(
                image,
                forKey: cacheKey as NSString
            )
''', 1)
repo_p.write_text(repo, encoding='utf-8')
PY

bash scripts/patch-3105-ipa-export.sh
bash scripts/patch-3105-app-manager-view-sort.sh
bash scripts/patch-3105-icon-performance.sh

grep -Fq 'allowedContentTypes: [.item]' "$SOURCES/FilzaSharedPairingSupport.swift"
grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' "$SOURCES/AppDataBrowserView.swift"
grep -Fq 'FILZA_3105_APP_VIEW_SORT_V2' "$SOURCES/AppDataBrowserView.swift"
grep -Fq 'Repackage as IPA' "$SOURCES/AppDataBrowserView.swift"
grep -Fq 'PackageRepositoryStore' "$SOURCES/PackageRepositoryStore.swift"
grep -Fq 'RepositoryHomeView' "$SOURCES/ThreeOneOSFiveContentView.swift"
grep -Fq 'return developerModeEnabled' "$SOURCES/AppTabNavigationState.swift"
! grep -Fq '.tabViewStyle(.page' "$SOURCES/ThreeOneOSFiveContentView.swift"
! grep -Fq 'minimumScaleFactor(0.62)' "$SOURCES/ThreeOneOSFiveContentView.swift"

git show 4200e37131463d1cac23d50e60f0a7545a0ce257:Filza3105Host.swift > Filza3105Host.swift
for name in LICENSE THIRD_PARTY_NOTICES.md UPSTREAM.md; do
  git show "origin/main:$ROOT/$name" > "$ROOT/$name"
done

(cd "$ROOT" && find UpstreamRepo -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) > "$ROOT/UPSTREAM_MANIFEST.sha256"

cat > scripts/verify-3105-pristine-integration.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT='ThirdParty/3105'
PIN='4a15d823b711bc0639de1f3fd2c764b5982d9245'
test "$(cat "$ROOT/UPSTREAM_PIN")" = "$PIN"
(cd "$ROOT" && shasum -a 256 -c UPSTREAM_MANIFEST.sha256 >/dev/null)
test -f "$ROOT/UpstreamRepo/ThreeOneOSFive/helpers/PackageRepositoryStore.swift"
test -f "$ROOT/Sources/PackageRepositoryStore.swift"
grep -Fq 'RepositoryHomeView' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'FeatureVisibility(developerModeEnabled: developerModeActive || forceFilesVisible)' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
grep -Fq 'return developerModeEnabled' "$ROOT/Sources/AppTabNavigationState.swift"
grep -Fq 'Filza3105PairingSettingsSection()' "$ROOT/Sources/ThreeOneOSFiveSettingsView.swift"
grep -Fq 'FilzaSharedPairingSupport.enhancedIcon' "$ROOT/Sources/AppDataBrowserView.swift"
grep -Fq 'FILZA_3105_APP_VIEW_SORT_V2' "$ROOT/Sources/AppDataBrowserView.swift"
grep -Fq 'Repackage as IPA' "$ROOT/Sources/AppDataBrowserView.swift"
! grep -Fq '.tabViewStyle(.page' "$ROOT/Sources/ThreeOneOSFiveContentView.swift"
! test -e scripts/patch-3105-feature-tabs.sh
! test -e scripts/patch-3105-compact-tabbar.sh
SH
chmod +x scripts/verify-3105-pristine-integration.sh

python3 - Makefile <<'PY'
from pathlib import Path
p = Path('Makefile')
t = p.read_text(encoding='utf-8')
t = t.replace('# stage-3105-v1.sh now stages immutable upstream 3105 1.1.1 directly while\n# preserving only Filza lifecycle/pairing/presentation adapters.\n', '# 3105 Sources is a committed integration layer generated from the pristine\n# pinned 2.0 vendor subtree, then Filza-owned adapters are applied on top.\n')
t = t.replace('\t@bash scripts/stage-3105-v1.sh\n\t@bash scripts/patch-3105-embedded-compat.sh\n', '\t@bash scripts/verify-3105-pristine-integration.sh\n')
t = t.replace('\t@test -f "scripts/patch-3105-embedded-compat.sh" || (echo "Missing 3105 embedded compatibility transform" >&2; exit 1)\n', '\t@test -f "scripts/verify-3105-pristine-integration.sh" || (echo "Missing pristine 3105 integration verifier" >&2; exit 1)\n')
p.write_text(t, encoding='utf-8')
PY

python3 - .github/workflows/verify-upstream-byetunes-ssh.yml <<'PY'
from pathlib import Path
p = Path('.github/workflows/verify-upstream-byetunes-ssh.yml')
t = p.read_text(encoding='utf-8')
t = t.replace("          grep -Fq 'stage-3105-v1.sh' Makefile\n          grep -Fq 'patch-3105-embedded-compat.sh' Makefile\n", "          grep -Fq 'verify-3105-pristine-integration.sh' Makefile\n          bash scripts/verify-3105-pristine-integration.sh\n")
p.write_text(t, encoding='utf-8')
PY

cat > .github/workflows/verify-3105-shared-ui.yml <<'YML'
name: Verify 3105 2.0 + Shared Embedded UI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

concurrency:
  group: verify-3105-shared-ui-${{ github.ref }}
  cancel-in-progress: true

jobs:
  source-contract:
    runs-on: macos-26-intel
    steps:
      - name: Checkout complete source tree
        uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Verify pristine upstream and Filza integration contracts
        shell: bash
        run: |
          set -euxo pipefail
          bash scripts/verify-3105-pristine-integration.sh
          grep -Fq '@StateObject private var patchStore = PatchProjectStore()' Filza3105Host.swift
          grep -Fq '@StateObject private var repositoryStore = PackageRepositoryStore()' Filza3105Host.swift
          grep -Fq 'initialTab: AppSection.home.rawValue' Filza3105Host.swift
          grep -Fq 'initialTab: AppSection.files.rawValue' Filza3105Host.swift
          grep -Fq 'initialTab: AppSection.installed.rawValue' Filza3105Host.swift
          grep -Fq 'FilzaEmbeddedPanel {' Filza3105Host.swift
          test -f ThirdParty/3105/Resources/Filza3105.bundle/UpstreamAppInfo.plist
          test "$(plutil -extract CFBundleShortVersionString raw -o - ThirdParty/3105/Resources/Filza3105.bundle/UpstreamAppInfo.plist)" = '2.0'
YML

rm -f .github/workflows/temp-bootstrap-pristine-3105.yml
rm -f .github/workflows/temp-reapply-filza-3105.yml
rm -f scripts/temp-reapply-3105.sh
rm -f scripts/stage-3105-v2-overlay.sh scripts/patch-3105-feature-tabs.sh scripts/patch-3105-compact-tabbar.sh

bash scripts/verify-3105-pristine-integration.sh
git diff --check

git add -A
git config user.name 'Filza-27 CI'
git config user.email 'actions@users.noreply.github.com'
git commit -m 'Reapply Filza 27 integration on pristine 3105 2.0'
git push origin HEAD:temp-3105-pristine-rebase
