#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105/Sources"
BROWSER="$ROOT/AppDataBrowserView.swift"

test -f "$BROWSER" || { echo "Missing 3105 Apps Manager source: $BROWSER" >&2; exit 1; }

python3 - "$BROWSER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = "FILZA_3105_APP_VIEW_SORT_V2"
if marker in text:
    print("3105 Apps Manager view/sort patch already applied")
    raise SystemExit(0)

# IPA export is applied immediately before this patch and gives us a stable
# state anchor without touching the existing app-row visual layout.
state_anchor = '''    @State private var ipaExportError: String?\n'''
state_replacement = '''    @State private var ipaExportError: String?\n\n    // FILZA_3105_APP_VIEW_SORT_V2\n    // Default preserves the exact existing 3105 Apps Manager list and order.\n    // Broader LaunchServices probing happens only for the explicit research views.\n    @State private var appViewMode: AppBrowserViewMode = .default\n    @State private var appSortOrder: AppBrowserSortOrder = .name\n    @State private var researchCandidates: [InstalledApp] = []\n    @State private var installedAPIBundleIDs: Set<String> = []\n    @State private var mcmBundleIDs: Set<String> = []\n    @State private var launchServicesBundleIDs: Set<String> = []\n    @State private var filesystemBundleIDs: Set<String> = []\n    @State private var launchServicesCandidateIdentifiers: [String] = []\n    @State private var isResearchCatalogLoading = false\n    @State private var didLoadResearchCatalog = false\n    @State private var researchCatalogRevision = 0\n'''
if state_anchor not in text:
    raise SystemExit("3105 view/sort patch: IPA export state anchor changed")
text = text.replace(state_anchor, state_replacement, 1)

filter_anchor = '''    private var filteredApps: [InstalledApp] {\n        guard !searchText.isEmpty else { return apps }\n        let q = searchText.lowercased()\n        return apps.filter {\n            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)\n        }\n    }\n'''
filter_replacement = '''    private var visibleApps: [InstalledApp] {\n        let source: [InstalledApp]\n        switch appViewMode {\n        case .default:\n            source = apps\n        case .userApps:\n            source = apps.filter { !$0.bundleID.lowercased().hasPrefix("com.apple.") }\n        case .appleApps:\n            source = apps.filter { $0.bundleID.lowercased().hasPrefix("com.apple.") }\n        case .internalHidden:\n            source = researchCandidates.filter { isInternalHiddenCandidate($0) }\n        case .systemServices:\n            source = researchCandidates.filter { isSystemServiceCandidate($0) }\n        case .unresolvedInteresting:\n            source = researchCandidates.filter {\n                $0.containerPath.isEmpty || isInternalHiddenCandidate($0)\n            }\n        }\n\n        // The normal screen remains byte-for-byte equivalent in behavior when\n        // Default + Name is selected: no additional filtering or re-sorting.\n        if appViewMode == .default && appSortOrder == .name {\n            return source\n        }\n        return sortedApps(source)\n    }\n\n    private var filteredApps: [InstalledApp] {\n        let source = visibleApps\n        guard !searchText.isEmpty else { return source }\n        let q = searchText.lowercased()\n        return source.filter {\n            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)\n        }\n    }\n'''
if filter_anchor not in text:
    raise SystemExit("3105 view/sort patch: filteredApps anchor changed")
text = text.replace(filter_anchor, filter_replacement, 1)

overlay_anchor = '''    private var overlayState: AppBrowserOverlayState {\n        if (isLoading || isResolving) && apps.isEmpty { return .loading }\n        if apps.isEmpty { return .empty }\n        if filteredApps.isEmpty { return .noResults }\n        return .none\n    }\n'''
overlay_replacement = '''    private var overlayState: AppBrowserOverlayState {\n        if (isLoading || isResolving || isResearchCatalogLoading) && visibleApps.isEmpty {\n            return .loading\n        }\n        if visibleApps.isEmpty { return .empty }\n        if filteredApps.isEmpty { return .noResults }\n        return .none\n    }\n'''
if overlay_anchor not in text:
    raise SystemExit("3105 view/sort patch: overlay anchor changed")
text = text.replace(overlay_anchor, overlay_replacement, 1)

# 3105 v1.0.1 has the existing FilesTab toolbar button before Refresh. Keep both
# exactly where they are and insert only the requested View / Sort menu.
toolbar_anchor = '''            .toolbar {\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    FilesTabToolbarButton(session: $tabSession)\n                }\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Button { reload() } label: {\n                        if isResolving {\n                            ProgressView()\n                        } else {\n                            Image(systemName: "arrow.clockwise")\n                        }\n                    }\n                    .disabled(isResolving)\n                    .accessibilityLabel(language.text("browser.retry"))\n                }\n            }\n'''
toolbar_replacement = '''            .toolbar {\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    FilesTabToolbarButton(session: $tabSession)\n                }\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Menu {\n                        Picker("View", selection: $appViewMode) {\n                            ForEach(AppBrowserViewMode.allCases) { mode in\n                                Text(mode.title).tag(mode)\n                            }\n                        }\n\n                        Divider()\n\n                        Picker("Sort", selection: $appSortOrder) {\n                            ForEach(AppBrowserSortOrder.allCases) { order in\n                                Text(order.title).tag(order)\n                            }\n                        }\n                    } label: {\n                        Image(systemName: "line.3.horizontal.decrease.circle")\n                    }\n                    .accessibilityLabel("View and sort apps")\n                }\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Button { reload() } label: {\n                        if isResolving || isResearchCatalogLoading {\n                            ProgressView()\n                        } else {\n                            Image(systemName: "arrow.clockwise")\n                        }\n                    }\n                    .disabled(isResolving || isResearchCatalogLoading)\n                    .accessibilityLabel(language.text("browser.retry"))\n                }\n            }\n'''
if toolbar_anchor not in text:
    raise SystemExit("3105 view/sort patch: v1.0.1 toolbar anchor changed")
text = text.replace(toolbar_anchor, toolbar_replacement, 1)

on_appear_anchor = '''            .onAppear {\n                if workspaceURL == nil {\n                    workspaceURL = try? PatchWorkspaceService.documentsRootURL()\n                    _ = try? PatchWorkspaceService.patchesRootURL()\n                }\n                if !hasLoaded {\n                    hasLoaded = true\n                    reload()\n                }\n            }\n'''
on_appear_replacement = '''            .onAppear {\n                if workspaceURL == nil {\n                    workspaceURL = try? PatchWorkspaceService.documentsRootURL()\n                    _ = try? PatchWorkspaceService.patchesRootURL()\n                }\n                if !hasLoaded {\n                    hasLoaded = true\n                    reload()\n                }\n            }\n            .onChange(of: appViewMode) { newMode in\n                if newMode.requiresResearchCatalog {\n                    loadResearchCatalogIfNeeded()\n                }\n            }\n'''
if on_appear_anchor not in text:
    raise SystemExit("3105 view/sort patch: v1.0.1 onAppear anchor changed")
text = text.replace(on_appear_anchor, on_appear_replacement, 1)

reload_start = '''    private func reload() {\n        isLoading = true\n        isResolving = true\n        errorMessage = nil\n'''
reload_replacement = '''    private func reload() {\n        researchCatalogRevision += 1\n        didLoadResearchCatalog = false\n        isResearchCatalogLoading = false\n        researchCandidates = []\n        launchServicesCandidateIdentifiers = []\n        isLoading = true\n        isResolving = true\n        errorMessage = nil\n'''
if reload_start not in text:
    raise SystemExit("3105 view/sort patch: reload start anchor changed")
text = text.replace(reload_start, reload_replacement, 1)

final_anchor = '''            DispatchQueue.main.async {\n                apps = result\n                isLoading = false\n                isResolving = false\n                if result.isEmpty {\n                    errorMessage = emptyMessage\n                }\n            }\n'''
final_replacement = '''            let apiIDs = Set(apiApps.map(\\.bundleID))\n            let mcmIDs = Set(mcmApps.map(\\.bundleID))\n            let launchServiceIDs = Set(launchServicesIdentifiers)\n            let inferredIDs = Set(inferredFilesystemApps.map(\\.bundleID))\n\n            DispatchQueue.main.async {\n                apps = result\n                researchCandidates = result\n                installedAPIBundleIDs = apiIDs\n                mcmBundleIDs = mcmIDs\n                launchServicesBundleIDs = launchServiceIDs\n                filesystemBundleIDs = inferredIDs\n                launchServicesCandidateIdentifiers = launchServicesIdentifiers\n                isLoading = false\n                isResolving = false\n                if result.isEmpty {\n                    errorMessage = emptyMessage\n                }\n                if appViewMode.requiresResearchCatalog {\n                    loadResearchCatalogIfNeeded()\n                }\n            }\n'''
if final_anchor not in text:
    raise SystemExit("3105 view/sort patch: final result anchor changed")
text = text.replace(final_anchor, final_replacement, 1)

reload_method_anchor = '''    private func reload() {\n'''
helpers = '''    private func sortedApps(_ source: [InstalledApp]) -> [InstalledApp] {\n        source.sorted { lhs, rhs in\n            switch appSortOrder {\n            case .name:\n                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)\n                if comparison != .orderedSame { return comparison == .orderedAscending }\n                return lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID) == .orderedAscending\n            case .bundleID:\n                let comparison = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)\n                if comparison != .orderedSame { return comparison == .orderedAscending }\n                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending\n            case .discovery:\n                let left = discoveryRank(for: lhs)\n                let right = discoveryRank(for: rhs)\n                if left != right { return left < right }\n                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending\n            }\n        }\n    }\n\n    private func discoveryRank(for app: InstalledApp) -> Int {\n        var rank = 0\n        if !installedAPIBundleIDs.contains(app.bundleID) { rank += 16 }\n        if !mcmBundleIDs.contains(app.bundleID) { rank += 8 }\n        if !launchServicesBundleIDs.contains(app.bundleID) { rank += 4 }\n        if !filesystemBundleIDs.contains(app.bundleID) { rank += 2 }\n        if app.containerPath.isEmpty { rank += 1 }\n        return rank\n    }\n\n    private func isInternalHiddenCandidate(_ app: InstalledApp) -> Bool {\n        let identifier = app.bundleID.lowercased()\n        let name = app.displayName.lowercased()\n        if AppBrowserResearchClassifier.matchesHiddenMarker(identifier) ||\n            AppBrowserResearchClassifier.matchesHiddenMarker(name) {\n            return true\n        }\n        guard identifier.hasPrefix("com.apple.") else { return false }\n        return !installedAPIBundleIDs.contains(app.bundleID) &&\n            (launchServicesBundleIDs.contains(app.bundleID) ||\n             mcmBundleIDs.contains(app.bundleID) ||\n             app.containerPath.isEmpty)\n    }\n\n    private func isSystemServiceCandidate(_ app: InstalledApp) -> Bool {\n        let identifier = app.bundleID.lowercased()\n        let name = app.displayName.lowercased()\n        guard identifier.hasPrefix("com.apple.") else { return false }\n        return app.containerPath.isEmpty ||\n            AppBrowserResearchClassifier.matchesServiceMarker(identifier) ||\n            AppBrowserResearchClassifier.matchesServiceMarker(name)\n    }\n\n    private func loadResearchCatalogIfNeeded() {\n        guard appViewMode.requiresResearchCatalog,\n              !isResolving,\n              !isResearchCatalogLoading,\n              !didLoadResearchCatalog,\n              !launchServicesCandidateIdentifiers.isEmpty else {\n            return\n        }\n\n        isResearchCatalogLoading = true\n        let revision = researchCatalogRevision\n        let baseApps = researchCandidates\n        let existingIDs = Set(baseApps.map(\\.bundleID))\n        let launchServiceCandidates = launchServicesCandidateIdentifiers\n        let researchIDs = ContainerStore.researchAppIdentifiers\n\n        DispatchQueue.global(qos: .utility).async {\n            let candidateIDs = AppBrowserResearchClassifier.researchCandidateIdentifiers(\n                research: researchIDs,\n                launchServices: launchServiceCandidates\n            )\n            var additions: [InstalledApp] = []\n            var seen = existingIDs\n\n            for bundleID in candidateIDs where seen.insert(bundleID).inserted {\n                let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]\n                guard rawInfo["found"] as? Bool == true else { continue }\n                additions.append(InstalledApp(\n                    bundleID: bundleID,\n                    name: rawInfo["name"] as? String ?? bundleID,\n                    containerPath: rawInfo["container"] as? String ?? "",\n                    version: rawInfo["version"] as? String ?? "",\n                    icon: nil\n                ))\n            }\n\n            let merged = baseApps + additions\n            DispatchQueue.main.async {\n                guard revision == researchCatalogRevision else { return }\n                researchCandidates = merged\n                isResearchCatalogLoading = false\n                didLoadResearchCatalog = true\n                log("browser: opt-in research catalog added \\(additions.count) installed LaunchServices candidates")\n            }\n        }\n    }\n\n    private func reload() {\n'''
if reload_method_anchor not in text:
    raise SystemExit("3105 view/sort patch: helper insertion anchor changed")
text = text.replace(reload_method_anchor, helpers, 1)

enum_anchor = '''private enum AppBrowserOverlayState: Equatable {\n'''
enums = '''private enum AppBrowserViewMode: String, CaseIterable, Identifiable {\n    case `default` = "default"\n    case userApps = "user-apps"\n    case appleApps = "apple-apps"\n    case internalHidden = "internal-hidden"\n    case systemServices = "system-services"\n    case unresolvedInteresting = "unresolved-interesting"\n\n    var id: String { rawValue }\n\n    var title: String {\n        switch self {\n        case .default: return "Default"\n        case .userApps: return "User Apps"\n        case .appleApps: return "Apple Apps"\n        case .internalHidden: return "Internal & Hidden"\n        case .systemServices: return "System / Services"\n        case .unresolvedInteresting: return "Unresolved / Interesting"\n        }\n    }\n\n    var requiresResearchCatalog: Bool {\n        switch self {\n        case .internalHidden, .systemServices, .unresolvedInteresting:\n            return true\n        case .default, .userApps, .appleApps:\n            return false\n        }\n    }\n}\n\nprivate enum AppBrowserSortOrder: String, CaseIterable, Identifiable {\n    case name\n    case bundleID = "bundle-id"\n    case discovery\n\n    var id: String { rawValue }\n\n    var title: String {\n        switch self {\n        case .name: return "Name"\n        case .bundleID: return "Bundle ID"\n        case .discovery: return "Discovery Source"\n        }\n    }\n}\n\nprivate enum AppBrowserResearchClassifier {\n    private static let hiddenMarkers = [\n        "internal", "diagnostic", "factory", "demo", "shelf", "field",\n        "seed", "prototype", "debug", "test", "developer", "setup",\n        "restore", "posterboard", "preferences", "settings", "incall",\n        "springboard", "backboard", "managed", "carrier", "provision"\n    ]\n\n    private static let serviceMarkers = [\n        "daemon", "service", "agent", "plugin", "extension", "springboard",\n        "backboard", "containermanager", "installd", "trustd", "securityd",\n        "mobileactivation", "diagnostic", "factory", "managed"\n    ]\n\n    static func matchesHiddenMarker(_ value: String) -> Bool {\n        let lower = value.lowercased()\n        return hiddenMarkers.contains { lower.contains($0) }\n    }\n\n    static func matchesServiceMarker(_ value: String) -> Bool {\n        let lower = value.lowercased()\n        return serviceMarkers.contains { lower.contains($0) }\n    }\n\n    static func researchCandidateIdentifiers(\n        research: [String],\n        launchServices: [String],\n        limit: Int = 1024\n    ) -> [String] {\n        var result: [String] = []\n        var seen = Set<String>()\n\n        func append(_ raw: String) {\n            guard result.count < limit else { return }\n            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)\n            guard identifier.lowercased().hasPrefix("com.apple."),\n                  ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier),\n                  seen.insert(identifier).inserted else {\n                return\n            }\n            result.append(identifier)\n        }\n\n        // Probe the known research catalog first, then retain the broad Apple\n        // LaunchServices set. Rows stay visually identical to the original list.\n        for identifier in research { append(identifier) }\n        for identifier in launchServices {\n            append(identifier)\n            if result.count >= limit { break }\n        }\n        return result\n    }\n}\n\nprivate enum AppBrowserOverlayState: Equatable {\n'''
if enum_anchor not in text:
    raise SystemExit("3105 view/sort patch: enum anchor changed")
text = text.replace(enum_anchor, enums, 1)

required = [
    marker,
    'Picker("View", selection: $appViewMode)',
    'Picker("Sort", selection: $appSortOrder)',
    'case internalHidden = "internal-hidden"',
    'case systemServices = "system-services"',
    'case unresolvedInteresting = "unresolved-interesting"',
    'if appViewMode == .default && appSortOrder == .name',
    'ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)',
    'Label("Repackage as IPA"',
]
for needle in required:
    if needle not in text:
        raise SystemExit(f"3105 view/sort patch contract failed: {needle}")

# Explicitly reject the UI the user asked us not to keep.
for forbidden in [
    'discoverySummary(for: app)',
    'NO DATA CONTAINER',
    'tags.joined(separator:',
]:
    if forbidden in text:
        raise SystemExit(f"3105 view/sort patch unexpectedly added discovery badges: {forbidden}")

path.write_text(text, encoding="utf-8")
PY

grep -Fq 'FILZA_3105_APP_VIEW_SORT_V2' "$BROWSER"
grep -Fq 'Picker("View", selection: $appViewMode)' "$BROWSER"
grep -Fq 'Picker("Sort", selection: $appSortOrder)' "$BROWSER"
grep -Fq 'case internalHidden = "internal-hidden"' "$BROWSER"
grep -Fq 'case systemServices = "system-services"' "$BROWSER"
grep -Fq 'case unresolvedInteresting = "unresolved-interesting"' "$BROWSER"
grep -Fq 'Label("Repackage as IPA"' "$BROWSER"
! grep -Fq 'discoverySummary(for: app)' "$BROWSER"

echo "Patched 3105 Apps Manager with View / Sort research modes and original row presentation"
