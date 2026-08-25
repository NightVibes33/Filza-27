import SwiftUI
import UIKit

struct AppDataBrowserView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = false
    @State private var isResolving = false
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var exportingBundleID: String?
    @State private var ipaExportItem: FilzaIPAExportItem?
    @State private var ipaExportError: String?

    // FILZA_3105_APP_VIEW_SORT_V2
    // Default preserves the exact existing 3105 Apps Manager list and order.
    // Broader LaunchServices probing happens only for the explicit research views.
    @State private var appViewMode: AppBrowserViewMode = .default
    @State private var appSortOrder: AppBrowserSortOrder = .name
    @State private var researchCandidates: [InstalledApp] = []
    @State private var installedAPIBundleIDs: Set<String> = []
    @State private var mcmBundleIDs: Set<String> = []
    @State private var launchServicesBundleIDs: Set<String> = []
    @State private var filesystemBundleIDs: Set<String> = []
    @State private var launchServicesCandidateIdentifiers: [String] = []
    @State private var isResearchCatalogLoading = false
    @State private var didLoadResearchCatalog = false
    @State private var researchCatalogRevision = 0
    @State private var workspaceURL: URL?
    @Binding private var tabSession: FilesTabSession
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    init(
        tabSession: Binding<FilesTabSession>,
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        _tabSession = tabSession
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
    }

    private var visibleApps: [InstalledApp] {
        let source: [InstalledApp]
        switch appViewMode {
        case .default:
            source = apps
        case .userApps:
            source = apps.filter { !$0.bundleID.lowercased().hasPrefix("com.apple.") }
        case .appleApps:
            source = apps.filter { $0.bundleID.lowercased().hasPrefix("com.apple.") }
        case .internalHidden:
            source = researchCandidates.filter { isInternalHiddenCandidate($0) }
        case .systemServices:
            source = researchCandidates.filter { isSystemServiceCandidate($0) }
        case .unresolvedInteresting:
            source = researchCandidates.filter {
                $0.containerPath.isEmpty || isInternalHiddenCandidate($0)
            }
        }

        // The normal screen remains byte-for-byte equivalent in behavior when
        // Default + Name is selected: no additional filtering or re-sorting.
        if appViewMode == .default && appSortOrder == .name {
            return source
        }
        return sortedApps(source)
    }

    private var filteredApps: [InstalledApp] {
        let source = visibleApps
        guard !searchText.isEmpty else { return source }
        let q = searchText.lowercased()
        return source.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    private var overlayState: AppBrowserOverlayState {
        if (isLoading || isResolving || isResearchCatalogLoading) && visibleApps.isEmpty {
            return .loading
        }
        if visibleApps.isEmpty { return .empty }
        if filteredApps.isEmpty { return .noResults }
        return .none
    }

    private var interfaceAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    var body: some View {
        navigationContent(tabID: tabSession.selectedTabID)
            .id(tabSession.selectedTabID)
    }

    private func navigationContent(tabID: UUID) -> some View {
        NavigationStack(path: navigationPath(for: tabID)) {
            appList
            .navigationTitle(language.text("browser.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    FilesTabToolbarButton(session: $tabSession)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("View", selection: $appViewMode) {
                            ForEach(AppBrowserViewMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        Divider()

                        Picker("Sort", selection: $appSortOrder) {
                            ForEach(AppBrowserSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("View and sort apps")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { reload() } label: {
                        if isResolving || isResearchCatalogLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isResolving || isResearchCatalogLoading)
                    .accessibilityLabel(language.text("browser.retry"))
                }
            }
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .onAppear {
                if workspaceURL == nil {
                    workspaceURL = try? PatchWorkspaceService.documentsRootURL()
                    _ = try? PatchWorkspaceService.patchesRootURL()
                }
                if !hasLoaded {
                    hasLoaded = true
                    reload()
                }
            }
            .onChange(of: appViewMode) { newMode in
                if newMode.requiresResearchCatalog {
                    loadResearchCatalogIfNeeded()
                }
            }
            .sheet(item: $ipaExportItem) { item in
                FilzaIPAExportDocumentPicker(item: item) {
                    ipaExportItem = nil
                }
            }
            .alert(
                "IPA Export",
                isPresented: Binding(
                    get: { ipaExportError != nil },
                    set: { if !$0 { ipaExportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { ipaExportError = nil }
            } message: {
                Text(ipaExportError ?? "Unknown IPA export error")
            }
            .navigationDestination(for: FileBrowserDestination.self) { destination in
                if destination.startPath == destination.containerPath {
                    FileBrowserView(
                        containerPath: destination.containerPath,
                        title: destination.title,
                        bundleID: destination.bundleID,
                        filesTabSession: $tabSession
                    )
                } else {
                    FileBrowserView(
                        containerPath: destination.containerPath,
                        startPath: destination.startPath,
                        title: destination.title,
                        bundleID: destination.bundleID,
                        filesTabSession: $tabSession
                    )
                }
            }
        }
    }

    private func navigationPath(for tabID: UUID) -> Binding<[FileBrowserDestination]> {
        Binding(
            get: { tabSession.navigationPath(for: tabID) },
            set: { tabSession.setNavigationPath($0, for: tabID) }
        )
    }

    private var appList: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .regular {
                FilesTabStrip(session: $tabSession)
            }
            AppSearchField(
                text: $searchText,
                prompt: language.text("browser.search"),
                clearLabel: language.text("common.clear")
            )
            Divider()
            appRows
        }
    }

    private var appRows: some View {
        List {
            if let workspaceURL {
                Section(language.text("browser.workspace")) {
                    let workspaceDestination = FileBrowserDestination(
                        containerPath: workspaceURL.path,
                        startPath: workspaceURL.path,
                        title: "3105",
                        bundleID: nil
                    )
                    NavigationLink(value: workspaceDestination) {
                        HStack(spacing: 10) {
                            AppRowIcon(systemName: "folder.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("3105")
                                    .font(.subheadline.weight(.semibold))
                                Text(language.text("browser.workspace_subtitle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        openInNewTabButton(workspaceDestination)
                    }
                }
            }
            Section {
                ForEach(filteredApps) { app in
                    if app.containerPath.isEmpty {
                        appRow(app)
                    } else {
                        let appDestination = FileBrowserDestination(
                            containerPath: app.containerPath,
                            startPath: app.containerPath,
                            title: app.displayName,
                            bundleID: app.bundleID
                        )
                        NavigationLink(value: appDestination) {
                            appRow(app)
                        }
                        .contextMenu {
                            openInNewTabButton(appDestination)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(language.text("browser.apps_count", Int64(filteredApps.count)))
                    Spacer()
                    if isResolving {
                        ProgressView()
                            .controlSize(.mini)
                        Text(language.text("browser.mha_scanning"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 48)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            Group {
                switch overlayState {
                case .loading:
                    ProgressView(language.text("browser.loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    emptyView
                case .noResults:
                    searchEmptyView
                case .none:
                    EmptyView()
                }
            }
            .transition(.opacity)
            .animation(interfaceAnimation, value: overlayState)
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            BrowserAppIcon(app: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if exportingBundleID == app.bundleID {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Repackaging IPA")
            } else if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        .contextMenu {
            Button {
                repackageToIPA(app)
            } label: {
                Label("Repackage as IPA", systemImage: "shippingbox.and.arrow.backward")
            }
            .disabled(exportingBundleID != nil)
        }
    }

    private func openInNewTabButton(_ destination: FileBrowserDestination) -> some View {
        Button {
            tabSession.openTab(navigationPath: [destination])
        } label: {
            Label(language.text("browser.open_new_tab"), systemImage: "square.on.square")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(errorMessage ?? language.text("browser.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Button(language.text("browser.retry")) { reload() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var searchEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("browser.search_empty"))
                .font(.subheadline.weight(.medium))
            Text(language.text("browser.search_apps_empty_message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func repackageToIPA(_ app: InstalledApp) {
        guard exportingBundleID == nil else { return }

        let bundleID = app.bundleID
        let displayName = app.displayName
        let version = app.version
        exportingBundleID = bundleID
        ipaExportError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try FilzaAppIPAExporter.repackage(
                    bundleID: bundleID,
                    displayName: displayName,
                    version: version
                )
                DispatchQueue.main.async {
                    exportingBundleID = nil
                    ipaExportItem = FilzaIPAExportItem(url: url)
                }
            } catch {
                DispatchQueue.main.async {
                    exportingBundleID = nil
                    ipaExportError = error.localizedDescription
                }
            }
        }
    }

    private func sortedApps(_ source: [InstalledApp]) -> [InstalledApp] {
        source.sorted { lhs, rhs in
            switch appSortOrder {
            case .name:
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID) == .orderedAscending
            case .bundleID:
                let comparison = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            case .discovery:
                let left = discoveryRank(for: lhs)
                let right = discoveryRank(for: rhs)
                if left != right { return left < right }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func discoveryRank(for app: InstalledApp) -> Int {
        var rank = 0
        if !installedAPIBundleIDs.contains(app.bundleID) { rank += 16 }
        if !mcmBundleIDs.contains(app.bundleID) { rank += 8 }
        if !launchServicesBundleIDs.contains(app.bundleID) { rank += 4 }
        if !filesystemBundleIDs.contains(app.bundleID) { rank += 2 }
        if app.containerPath.isEmpty { rank += 1 }
        return rank
    }

    private func isInternalHiddenCandidate(_ app: InstalledApp) -> Bool {
        let identifier = app.bundleID.lowercased()
        let name = app.displayName.lowercased()
        if AppBrowserResearchClassifier.matchesHiddenMarker(identifier) ||
            AppBrowserResearchClassifier.matchesHiddenMarker(name) {
            return true
        }
        guard identifier.hasPrefix("com.apple.") else { return false }
        return !installedAPIBundleIDs.contains(app.bundleID) &&
            (launchServicesBundleIDs.contains(app.bundleID) ||
             mcmBundleIDs.contains(app.bundleID) ||
             app.containerPath.isEmpty)
    }

    private func isSystemServiceCandidate(_ app: InstalledApp) -> Bool {
        let identifier = app.bundleID.lowercased()
        let name = app.displayName.lowercased()
        guard identifier.hasPrefix("com.apple.") else { return false }
        return app.containerPath.isEmpty ||
            AppBrowserResearchClassifier.matchesServiceMarker(identifier) ||
            AppBrowserResearchClassifier.matchesServiceMarker(name)
    }

    private func loadResearchCatalogIfNeeded() {
        guard appViewMode.requiresResearchCatalog,
              !isResolving,
              !isResearchCatalogLoading,
              !didLoadResearchCatalog,
              !launchServicesCandidateIdentifiers.isEmpty else {
            return
        }

        isResearchCatalogLoading = true
        let revision = researchCatalogRevision
        let baseApps = researchCandidates
        let existingIDs = Set(baseApps.map(\.bundleID))
        let launchServiceCandidates = launchServicesCandidateIdentifiers
        let researchIDs = ContainerStore.researchAppIdentifiers

        DispatchQueue.global(qos: .utility).async {
            let candidateIDs = AppBrowserResearchClassifier.researchCandidateIdentifiers(
                research: researchIDs,
                launchServices: launchServiceCandidates
            )
            var additions: [InstalledApp] = []
            var seen = existingIDs

            for bundleID in candidateIDs where seen.insert(bundleID).inserted {
                let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                guard rawInfo["found"] as? Bool == true else { continue }
                additions.append(InstalledApp(
                    bundleID: bundleID,
                    name: rawInfo["name"] as? String ?? bundleID,
                    containerPath: rawInfo["container"] as? String ?? "",
                    version: rawInfo["version"] as? String ?? "",
                    icon: nil
                ))
            }

            let merged = baseApps + additions
            DispatchQueue.main.async {
                guard revision == researchCatalogRevision else { return }
                researchCandidates = merged
                isResearchCatalogLoading = false
                didLoadResearchCatalog = true
                log("browser: opt-in research catalog added \(additions.count) installed LaunchServices candidates")
            }
        }
    }

    private func reload() {
        researchCatalogRevision += 1
        didLoadResearchCatalog = false
        isResearchCatalogLoading = false
        researchCandidates = []
        launchServicesCandidateIdentifiers = []
        isLoading = true
        isResolving = true
        errorMessage = nil
        let emptyMessage = language.text("browser.empty")
        DispatchQueue.global(qos: .userInitiated).async {
            let bundleMetadata = ContainerStore.applicationBundleMetadataCatalog()
            let apiApps = ContainerStore.applyingBundleMetadata(
                to: ContainerStore.installedAppsFromAPI(),
                catalog: bundleMetadata
            )
            if apiApps.isEmpty {
                log("browser: installed-app API unavailable; trying MCM class-2 enumeration...")
            }
            let dynamicIdentifiers = ContainerStore.dynamicAppIdentifiers()
            let mcmApps = ContainerStore.installedAppsFromMCM(
                identifiers: dynamicIdentifiers,
                bundleMetadata: bundleMetadata
            )
            let filesystemApps = ContainerStore.containersFromFilesystem()
            let baseIdentifiedApps = mcmApps + apiApps
            var result = ContainerDiscoveryMerger.merge(
                enumerated: filesystemApps,
                identified: baseIdentifiedApps,
                path: { $0.containerPath }
            )
            log("browser: merged api=\(apiApps.count), MCM=\(mcmApps.count), filesystem=\(filesystemApps.count) -> \(result.count)")
            result.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            let preliminary = result.filter {
                ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)
            }
            DispatchQueue.main.async {
                apps = preliminary
                isLoading = false
            }

            let launchServicesIdentifiers = ContainerStore.launchServicesStoreIdentifiers()
            let mhaIdentifiers = MHAIdentifierCatalog.identifiers(
                dynamic: dynamicIdentifiers,
                installed: apiApps.map(\.bundleID),
                research: ContainerStore.researchAppIdentifiers,
                custom: bundleMetadata.keys.sorted(),
                launchServices: launchServicesIdentifiers
            )
            log(
                "browser: MHA catalog dynamic=\(dynamicIdentifiers.count), " +
                "installed=\(apiApps.count), research=\(ContainerStore.researchAppIdentifiers.count), " +
                "LaunchServices=\(launchServicesIdentifiers.count) -> \(mhaIdentifiers.count) candidates"
            )
            let mhaApps = ContainerStore.installedAppsFromMHACandidates(
                identifiers: mhaIdentifiers,
                bundleMetadata: bundleMetadata
            ) { discoveredApps in
                var progressiveResult = AppDataCatalogMerger.merge(
                    identified: discoveredApps + baseIdentifiedApps,
                    fallback: [],
                    identifier: { $0.bundleID },
                    path: { $0.containerPath }
                )
                progressiveResult = progressiveResult.filter {
                    ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)
                }
                progressiveResult.sort {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                DispatchQueue.main.async {
                    apps = progressiveResult
                }
            }

            let allKnownApps = mhaApps + baseIdentifiedApps
            let identifiedPaths = Set(allKnownApps.map {
                ContainerDiscoveryMerger.canonicalPath($0.containerPath)
            })
            let unmatchedFilesystemApps = filesystemApps.filter {
                !identifiedPaths.contains(
                    ContainerDiscoveryMerger.canonicalPath($0.containerPath)
                )
            }
            let inferredFilesystemApps = ContainerStore.inferUnidentifiedApps(
                in: unmatchedFilesystemApps,
                knownApps: allKnownApps,
                launchServicesIdentifiers: Set(launchServicesIdentifiers)
            ).filter {
                ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)
            }
            result = AppDataCatalogMerger.merge(
                identified: allKnownApps,
                fallback: inferredFilesystemApps,
                identifier: { $0.bundleID },
                path: { $0.containerPath }
            )
            result = result.filter {
                ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)
            }
            result.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            let apiIDs = Set(apiApps.map(\.bundleID))
            let mcmIDs = Set(mcmApps.map(\.bundleID))
            let launchServiceIDs = Set(launchServicesIdentifiers)
            let inferredIDs = Set(inferredFilesystemApps.map(\.bundleID))

            DispatchQueue.main.async {
                apps = result
                researchCandidates = result
                installedAPIBundleIDs = apiIDs
                mcmBundleIDs = mcmIDs
                launchServicesBundleIDs = launchServiceIDs
                filesystemBundleIDs = inferredIDs
                launchServicesCandidateIdentifiers = launchServicesIdentifiers
                isLoading = false
                isResolving = false
                if result.isEmpty {
                    errorMessage = emptyMessage
                }
                if appViewMode.requiresResearchCatalog {
                    loadResearchCatalogIfNeeded()
                }
            }
        }
    }
}

private enum AppBrowserViewMode: String, CaseIterable, Identifiable {
    case `default` = "default"
    case userApps = "user-apps"
    case appleApps = "apple-apps"
    case internalHidden = "internal-hidden"
    case systemServices = "system-services"
    case unresolvedInteresting = "unresolved-interesting"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .userApps: return "User Apps"
        case .appleApps: return "Apple Apps"
        case .internalHidden: return "Internal & Hidden"
        case .systemServices: return "System / Services"
        case .unresolvedInteresting: return "Unresolved / Interesting"
        }
    }

    var requiresResearchCatalog: Bool {
        switch self {
        case .internalHidden, .systemServices, .unresolvedInteresting:
            return true
        case .default, .userApps, .appleApps:
            return false
        }
    }
}

private enum AppBrowserSortOrder: String, CaseIterable, Identifiable {
    case name
    case bundleID = "bundle-id"
    case discovery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .bundleID: return "Bundle ID"
        case .discovery: return "Discovery Source"
        }
    }
}

private enum AppBrowserResearchClassifier {
    private static let hiddenMarkers = [
        "internal", "diagnostic", "factory", "demo", "shelf", "field",
        "seed", "prototype", "debug", "test", "developer", "setup",
        "restore", "posterboard", "preferences", "settings", "incall",
        "springboard", "backboard", "managed", "carrier", "provision"
    ]

    private static let serviceMarkers = [
        "daemon", "service", "agent", "plugin", "extension", "springboard",
        "backboard", "containermanager", "installd", "trustd", "securityd",
        "mobileactivation", "diagnostic", "factory", "managed"
    ]

    static func matchesHiddenMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return hiddenMarkers.contains { lower.contains($0) }
    }

    static func matchesServiceMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return serviceMarkers.contains { lower.contains($0) }
    }

    static func researchCandidateIdentifiers(
        research: [String],
        launchServices: [String],
        limit: Int = 1024
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            guard result.count < limit else { return }
            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identifier.lowercased().hasPrefix("com.apple."),
                  ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier),
                  seen.insert(identifier).inserted else {
                return
            }
            result.append(identifier)
        }

        // Probe the known research catalog first, then retain the broad Apple
        // LaunchServices set. Rows stay visually identical to the original list.
        for identifier in research { append(identifier) }
        for identifier in launchServices {
            append(identifier)
            if result.count >= limit { break }
        }
        return result
    }
}

private enum AppBrowserOverlayState: Equatable {
    case loading
    case empty
    case noResults
    case none
}

struct BrowserAppIcon: View {
    let app: InstalledApp
    @State private var resolvedIcon: UIImage?
    @State private var didRequestIcon = false

    init(app: InstalledApp) {
        self.app = app
        _resolvedIcon = State(initialValue: app.icon)
    }

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(uiImage: resolvedIcon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app")
                    .font(.system(size: AppTheme.rowIconSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: AppTheme.appIconSize, height: AppTheme.appIconSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
        .onAppear {
            guard !didRequestIcon else { return }
            didRequestIcon = true
            let bundleID = app.bundleID
            // Paint the existing LaunchServices icon immediately so the
            // list never waits on the paired SpringBoard service.
            if resolvedIcon == nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    let fallbackIcon = iconForBundleID(bundleID)
                    guard let fallbackIcon else { return }
                    DispatchQueue.main.async {
                        if resolvedIcon == nil {
                            resolvedIcon = fallbackIcon
                        }
                    }
                }
            }

            // Upgrade the row asynchronously when SpringBoardServices returns
            // the rendered icon. Visible rows naturally request first.
            Task { @MainActor in
                if let icon = await FilzaSharedPairingSupport.enhancedIcon(for: bundleID) {
                    resolvedIcon = icon
                }
            }
        }
    }
}
