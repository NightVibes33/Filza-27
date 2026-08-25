#!/usr/bin/env bash
set -euo pipefail

CONTENT="ThirdParty/3105/Sources/ThreeOneOSFiveContentView.swift"
NAVIGATION="ThirdParty/3105/Sources/AppTabNavigationState.swift"

for path in "$CONTENT" "$NAVIGATION"; do
  test -f "$path" || { echo "Missing staged 3105 feature-tab source: $path" >&2; exit 1; }
done

python3 - "$CONTENT" "$NAVIGATION" <<'PY'
from pathlib import Path
import sys

content_path = Path(sys.argv[1])
navigation_path = Path(sys.argv[2])
content = content_path.read_text(encoding="utf-8")
navigation = navigation_path.read_text(encoding="utf-8")

# Upstream 2.0 kept the Cleaner preference but dropped Cleaner from AppSection,
# leaving the toggle with no UI destination. Restore the existing 3105 Cleaner
# view as an appended section so upstream raw values 0...5 remain unchanged.
old_enum = '''    case files
    case search
'''
new_enum = '''    case files
    case search
    case cleaner
'''
if old_enum not in navigation:
    raise SystemExit("3105 feature tabs: AppSection enum anchor changed")
navigation = navigation.replace(old_enum, new_enum, 1)

old_visibility_state = '''    let developerModeEnabled: Bool

    init(developerModeEnabled: Bool) {
        self.developerModeEnabled = developerModeEnabled
    }
'''
new_visibility_state = '''    let developerModeEnabled: Bool
    let cleanerEnabled: Bool

    init(developerModeEnabled: Bool, cleanerEnabled: Bool) {
        self.developerModeEnabled = developerModeEnabled
        self.cleanerEnabled = cleanerEnabled
    }
'''
if old_visibility_state not in navigation:
    raise SystemExit("3105 feature tabs: FeatureVisibility state anchor changed")
navigation = navigation.replace(old_visibility_state, new_visibility_state, 1)

# Keep Apple's native compact UITabBar. It has five visible slots, so when a
# feature toggle is enabled we prioritize that feature into those five slots
# instead of replacing the tab container or squeezing seven custom buttons into
# the iPhone width. Lower-priority repository tabs remain reachable via native
# More only when necessary.
old_visible_sections = '''    var visibleSections: [AppSection] {
        AppSection.allCases.filter(isVisible)
    }
'''
new_visible_sections = '''    var visibleSections: [AppSection] {
        if developerModeEnabled && cleanerEnabled {
            return [.home, .new, .installed, .files, .cleaner, .sources, .search]
        }

        var sections: [AppSection] = [.home, .new, .sources, .installed]
        if developerModeEnabled { sections.append(.files) }
        if cleanerEnabled { sections.append(.cleaner) }
        sections.append(.search)
        return sections
    }
'''
if old_visible_sections not in navigation:
    raise SystemExit("3105 feature tabs: visibleSections anchor changed")
navigation = navigation.replace(old_visible_sections, new_visible_sections, 1)

# stage-3105-v2-overlay intentionally made Files always visible to preserve the
# Filza Apps Manager route. Move that exception into ContentView so it applies
# only when Filza actually opens the dedicated Apps Manager controller. In the
# normal 3105 workspace, Developer Mode once again controls the Files tab.
old_visibility_switch = '''        case .files:
            return true
        default:
            return true
'''
new_visibility_switch = '''        case .files:
            return developerModeEnabled
        case .cleaner:
            return cleanerEnabled
        default:
            return true
'''
if old_visibility_switch not in navigation:
    raise SystemExit("3105 feature tabs: staged Files visibility anchor changed")
navigation = navigation.replace(old_visibility_switch, new_visibility_switch, 1)
navigation_path.write_text(navigation, encoding="utf-8")

old_properties = '''    @AppStorage(FeatureVisibility.developerModeStorageKey)
    private var developerModeEnabled = false
    @State private var tabNavigation: AppTabNavigationState
'''
new_properties = '''    @AppStorage(FeatureVisibility.developerModeStorageKey)
    private var developerModeEnabled = false
    @AppStorage(FeatureVisibility.cleanerStorageKey)
    private var cleanerEnabled = true
    private let forceFilesVisible: Bool
    @State private var tabNavigation: AppTabNavigationState
'''
if old_properties not in content:
    raise SystemExit("3105 feature tabs: ContentView feature-state anchor changed")
content = content.replace(old_properties, new_properties, 1)

old_init = '''    init(initialTab requestedInitialTab: Int = AppSection.home.rawValue) {
#if targetEnvironment(simulator)
'''
new_init = '''    init(initialTab requestedInitialTab: Int = AppSection.home.rawValue) {
        forceFilesVisible = requestedInitialTab == AppSection.files.rawValue
#if targetEnvironment(simulator)
'''
if old_init not in content:
    raise SystemExit("3105 feature tabs: embedded ContentView init anchor changed")
content = content.replace(old_init, new_init, 1)

old_onchange = '''        .onChange(of: developerModeEnabled) { _ in
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
        .onAppear {
'''
new_onchange = '''        .onChange(of: developerModeEnabled) { _ in
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
        .onChange(of: cleanerEnabled) { _ in
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
        .onAppear {
'''
if old_onchange not in content:
    raise SystemExit("3105 feature tabs: Developer Mode change-handler anchor changed")
content = content.replace(old_onchange, new_onchange, 1)

old_search_case = '''        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        }
'''
new_search_case = '''        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .cleaner:
            CleanerView()
        }
'''
if old_search_case not in content:
    raise SystemExit("3105 feature tabs: sectionContent search anchor changed")
content = content.replace(old_search_case, new_search_case, 1)

old_feature_visibility = '''    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(developerModeEnabled: developerModeActive)
    }
'''
new_feature_visibility = '''    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(
            developerModeEnabled: developerModeActive || forceFilesVisible,
            cleanerEnabled: cleanerEnabled
        )
    }
'''
if old_feature_visibility not in content:
    raise SystemExit("3105 feature tabs: ContentView FeatureVisibility anchor changed")
content = content.replace(old_feature_visibility, new_feature_visibility, 1)

old_title = '''        case .files: return "tab.files"
        case .search: return "tab.search"
'''
new_title = '''        case .files: return "tab.files"
        case .search: return "tab.search"
        case .cleaner: return "tab.cleaner"
'''
if old_title not in content:
    raise SystemExit("3105 feature tabs: tab title anchor changed")
content = content.replace(old_title, new_title, 1)

old_icon = '''        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
'''
new_icon = '''        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
        case .cleaner: return "sparkles"
'''
if old_icon not in content:
    raise SystemExit("3105 feature tabs: tab icon anchor changed")
content = content.replace(old_icon, new_icon, 1)

content_path.write_text(content, encoding="utf-8")
PY

grep -Fq 'case cleaner' "$NAVIGATION"
grep -Fq 'return developerModeEnabled' "$NAVIGATION"
grep -Fq 'return cleanerEnabled' "$NAVIGATION"
grep -Fq 'return [.home, .new, .installed, .files, .cleaner, .sources, .search]' "$NAVIGATION"
grep -Fq '@AppStorage(FeatureVisibility.cleanerStorageKey)' "$CONTENT"
grep -Fq 'forceFilesVisible = requestedInitialTab == AppSection.files.rawValue' "$CONTENT"
grep -Fq 'developerModeEnabled: developerModeActive || forceFilesVisible' "$CONTENT"
grep -Fq 'case .cleaner:' "$CONTENT"
grep -Fq 'CleanerView()' "$CONTENT"
grep -Fq '.tabItem {' "$CONTENT"
! grep -Fq '.tabViewStyle(.page' "$CONTENT"

echo "Restored native 3105 tabs with feature-priority ordering and Filza Apps Manager routing"
