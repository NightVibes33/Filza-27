import Foundation

enum AppSection: Int, CaseIterable, Identifiable {
    case home
    case new
    case sources
    case installed
    case files
    case search

    var id: Int { rawValue }
}

enum WallpaperFeatureSupportPolicy {
    static func isSupported(major: Int) -> Bool {
        switch major {
        case 17, 18, 26, 27:
            return true
        default:
            return false
        }
    }
}

struct OneShotPresentationGate: Equatable {
    private(set) var hasClaimed = false

    mutating func claim() -> Bool {
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
}

struct FeatureVisibility: Equatable {
    static let cleanerStorageKey = "feature.cleaner.enabled"
    static let developerModeStorageKey = "feature.developer_mode.enabled"

    let developerModeEnabled: Bool

    init(developerModeEnabled: Bool) {
        self.developerModeEnabled = developerModeEnabled
    }

    var visibleSections: [AppSection] {
        AppSection.allCases.filter(isVisible)
    }

    func isVisible(_ section: AppSection) -> Bool {
        switch section {
        case .files:
            return developerModeEnabled
        default:
            return true
        }
    }
}

struct AppTabNavigationState: Equatable {
    private(set) var selectedTab: Int
    private(set) var filesTabs: FilesTabSession

    init(
        selectedTab: Int = 0,
        filesNavigationPath: [FileBrowserDestination] = []
    ) {
        self.selectedTab = selectedTab
        var session = FilesTabSession()
        session.setActiveNavigationPath(filesNavigationPath)
        filesTabs = session
    }

    mutating func select(_ tab: Int) {
        selectedTab = tab
    }

    mutating func setFilesNavigationPath(_ path: [FileBrowserDestination]) {
        filesTabs.setActiveNavigationPath(path)
    }

    var filesNavigationPath: [FileBrowserDestination] {
        filesTabs.activeTab?.navigationPath ?? []
    }

    mutating func setFilesTabs(_ session: FilesTabSession) {
        filesTabs = session
    }

    mutating func reconcileSelection(with visibility: FeatureVisibility) {
        guard let selectedSection = AppSection(rawValue: selectedTab),
              visibility.isVisible(selectedSection) else {
            selectedTab = AppSection.home.rawValue
            return
        }
    }
}

struct FileBrowserDestination: Hashable {
    let containerPath: String
    let startPath: String
    let title: String
    let bundleID: String?
}

struct FilesTabState: Identifiable, Equatable {
    let id: UUID
    var customTitle: String?
    var navigationPath: [FileBrowserDestination]

    func displayTitle(defaultTitle: String) -> String {
        customTitle ?? navigationPath.last?.title ?? defaultTitle
    }

    var currentPath: String? {
        navigationPath.last?.startPath
    }
}

struct FilesTabSession: Equatable {
    private(set) var tabs: [FilesTabState]
    private(set) var selectedTabID: UUID

    init(initialTabID: UUID = UUID()) {
        tabs = [FilesTabState(id: initialTabID, customTitle: nil, navigationPath: [])]
        selectedTabID = initialTabID
    }

    var activeTab: FilesTabState? {
        tabs.first { $0.id == selectedTabID }
    }

    func navigationPath(for id: UUID) -> [FileBrowserDestination] {
        tabs.first { $0.id == id }?.navigationPath ?? []
    }

    mutating func setNavigationPath(_ path: [FileBrowserDestination], for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].navigationPath = path
    }

    mutating func setActiveNavigationPath(_ path: [FileBrowserDestination]) {
        setNavigationPath(path, for: selectedTabID)
    }

    mutating func openTab(
        id: UUID = UUID(),
        navigationPath: [FileBrowserDestination] = []
    ) {
        tabs.append(FilesTabState(id: id, customTitle: nil, navigationPath: navigationPath))
        selectedTabID = id
    }

    mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    mutating func renameTab(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    mutating func closeTab(_ id: UUID, replacementID: UUID = UUID()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            tabs = [FilesTabState(id: replacementID, customTitle: nil, navigationPath: [])]
            selectedTabID = replacementID
            return
        }

        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    mutating func closeOtherTabs(keeping id: UUID) {
        guard let keptTab = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keptTab]
        selectedTabID = id
    }
}
