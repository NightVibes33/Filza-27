#!/usr/bin/env bash
set -euo pipefail

ROOT="ThirdParty/3105/Sources"
BROWSER="$ROOT/AppDataBrowserView.swift"

test -f "$BROWSER" || { echo "Missing 3105 Apps Manager source: $BROWSER" >&2; exit 1; }

python3 - "$BROWSER" <<'PY'
from pathlib import Path
import sys

browser_path = Path(sys.argv[1])
browser = browser_path.read_text(encoding="utf-8")

marker = "FILZA_3105_APP_RESEARCH_SORT_V1"
if marker in browser:
    print("3105 Apps Manager research/sort patch already applied")
    raise SystemExit(0)

state_anchor = '''    @State private var ipaExportError: String?\n'''
state_replacement = '''    @State private var ipaExportError: String?\n\n    // FILZA_3105_APP_RESEARCH_SORT_V1\n    // Default mode continues to render the exact existing Apps Manager result.\n    // The broader research catalog is populated lazily only when an opt-in\n    // internal/system/unresolved view is selected.\n    @State private var appViewMode: AppBrowserViewMode = .default\n    @State private var appSortOrder: AppBrowserSortOrder = .name\n    @State private var researchCandidates: [InstalledApp] = []\n    @State private var installedAPIBundleIDs: Set<String> = []\n    @State private var mcmBundleIDs: Set<String> = []\n    @State private var launchServicesBundleIDs: Set<String> = []\n    @State private var researchBundleIDs: Set<String> = []\n    @State private var filesystemBundleIDs: Set<String> = []\n    @State private var launchServicesCandidateIdentifiers: [String] = []\n    @State private var isResearchCatalogLoading = false\n    @State private var didLoadResearchCatalog = false\n    @State private var researchCatalogRevision = 0\n'''
if state_anchor not in browser:
    raise SystemExit("3105 app research patch: IPA exporter state anchor changed")
browser = browser.replace(state_anchor, state_replacement, 1)

filter_anchor = '''    private var filteredApps: [InstalledApp] {\n        guard !searchText.isEmpty else { return apps }\n        let q = searchText.lowercased()\n        return apps.filter {\n            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)\n        }\n    }\n'''
filter_replacement = '''    private var visibleApps: [InstalledApp] {\n        let source: [InstalledApp]\n        switch appViewMode {\n        case .default:\n            source = apps\n        case .userApps:\n            source = apps.filter { !$0.bundleID.lowercased().hasPrefix("com.apple.") }\n        case .appleApps:\n            source = apps.filter { $0.bundleID.lowercased().hasPrefix("com.apple.") }\n        case .internalHidden:\n            source = researchCandidates.filter { isInternalHiddenCandidate($0) }\n        case .systemServices:\n            source = researchCandidates.filter { isSystemServiceCandidate($0) }\n        case .unresolvedInteresting:\n            source = researchCandidates.filter {\n                $0.containerPath.isEmpty || isInternalHiddenCandidate($0)\n            }\n        }\n\n        // Preserve the exact upstream/current default ordering unless the user\n        // explicitly asks for another sort.\n        if appViewMode == .default && appSortOrder == .name {\n            return source\n        }\n        return sortedApps(source)\n    }\n\n    private var filteredApps: [InstalledApp] {\n        let source = visibleApps\n        guard !searchText.isEmpty else { return source }\n        let q = searchText.lowercased()\n        return source.filter {\n            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)\n        }\n    }\n'''
if filter_anchor not in browser:
    raise SystemExit("3105 app research patch: filteredApps anchor changed")
browser = browser.replace(filter_anchor, filter_replacement, 1)

old_overlay = '''    private var overlayState: AppBrowserOverlayState {\n        if (isLoading || isResolving) && apps.isEmpty { return .loading }\n        if apps.isEmpty { return .empty }\n        if filteredApps.isEmpty { return .noResults }\n        return .none\n    }\n'''
new_overlay = '''    private var overlayState: AppBrowserOverlayState {\n        if (isLoading || isResolving || isResearchCatalogLoading) && visibleApps.isEmpty {\n            return .loading\n        }\n        if visibleApps.isEmpty { return .empty }\n        if filteredApps.isEmpty { return .noResults }\n        return .none\n    }\n'''
if old_overlay not in browser:
    raise SystemExit("3105 app research patch: overlay anchor changed")
browser = browser.replace(old_overlay, new_overlay, 1)

toolbar_anchor = '''            .toolbar {\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Button { reload() } label: {\n                        if isResolving {\n                            ProgressView()\n                        } else {\n                            Image(systemName: "arrow.clockwise")\n                        }\n                    }\n                    .disabled(isResolving)\n                    .accessibilityLabel(language.text("browser.retry"))\n                }\n            }\n'''
toolbar_replacement = '''            .toolbar {\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Menu {\n                        Picker("View", selection: $appViewMode) {\n                            ForEach(AppBrowserViewMode.allCases) { mode in\n                                Text(mode.title).tag(mode)\n                            }\n                        }\n\n                        Divider()\n\n                        Picker("Sort", selection: $appSortOrder) {\n                            ForEach(AppBrowserSortOrder.allCases) { order in\n                                Text(order.title).tag(order)\n                            }\n                        }\n                    } label: {\n                        Image(systemName: "line.3.horizontal.decrease.circle")\n                    }\n                    .accessibilityLabel("View and sort apps")\n                }\n\n                ToolbarItem(placement: .navigationBarTrailing) {\n                    Button { reload() } label: {\n                        if isResolving || isResearchCatalogLoading {\n                            ProgressView()\n                        } else {\n                            Image(systemName: "arrow.clockwise")\n                        }\n                    }\n                    .disabled(isResolving || isResearchCatalogLoading)\n                    .accessibilityLabel(language.text("browser.retry"))\n                }\n            }\n'''
if toolbar_anchor not in browser:
    raise SystemExit("3105 app research patch: toolbar anchor changed")
browser = browser.replace(toolbar_anchor, toolbar_replacement, 1)

on_appear_anchor = '''            .onAppear {\n                if !hasLoaded {\n                    hasLoaded = true\n                    reload()\n                }\n            }\n'''
on_appear_replacement = '''            .onAppear {\n                if !hasLoaded {\n                    hasLoaded = true\n                    reload()\n                }\n            }\n            .onChange(of: appViewMode) { newMode in\n                if newMode.requiresResearchCatalog {\n                    loadResearchCatalogIfNeeded()\n                }\n            }\n'''
if on_appear_anchor not in browser:
    raise SystemExit("3105 app research patch: onAppear anchor changed")
browser = browser.replace(on_appear_anchor, on_appear_replacement, 1)

header_anchor = '''                    Text(language.text("browser.apps_count", Int64(filteredApps.count)))\n                    Spacer()\n                    if isResolving {\n                        ProgressView()\n                            .controlSize(.mini)\n                        Text(language.text("browser.mha_scanning"))\n                    }\n'''
header_replacement = '''                    Text(language.text("browser.apps_count", Int64(filteredApps.count)))\n                    if appViewMode != .default {\n                        Text("· \\(appViewMode.title)")\n                    }\n                    Spacer()\n                    if isResearchCatalogLoading {\n                        ProgressView()\n                            .controlSize(.mini)\n                        Text("Scanning hidden apps…")\n                    } else if isResolving {\n                        ProgressView()\n                            .controlSize(.mini)\n                        Text(language.text("browser.mha_scanning"))\n                    }\n'''
if header_anchor not in browser:
    raise SystemExit("3105 app research patch: section header anchor changed")
browser = browser.replace(header_anchor, header_replacement, 1)

bundle_label_anchor = '''                Text(app.bundleID)\n                    .font(.caption2.monospaced())\n                    .foregroundStyle(.secondary)\n                    .lineLimit(1)\n                    .truncationMode(.middle)\n'''
bundle_label_replacement = '''                Text(app.bundleID)\n                    .font(.caption2.monospaced())\n                    .foregroundStyle(.secondary)\n                    .lineLimit(1)\n                    .truncationMode(.middle)\n\n                if appViewMode != .default {\n                    Text(discoverySummary(for: app))\n                        .font(.system(size: 9, weight: .medium, design: .monospaced))\n                        .foregroundStyle(.tertiary)\n                        .lineLimit(1)\n                }\n'''
if bundle_label_anchor not in browser:
    raise SystemExit("3105 app research patch: row bundle label anchor changed")
browser = browser.replace(bundle_label_anchor, bundle_label_replacement, 1)

reload_anchor = '''    private func reload() {\n        isLoading = true\n        isResolving = true\n        errorMessage = nil\n'''
reload_replacement = '''    private func reload() {\n        researchCatalogRevision += 1\n        didLoadResearchCatalog = false\n        isResearchCatalogLoading = false\n        launchServicesCandidateIdentifiers = []\n        isLoading = true\n        isResolving = true\n        errorMessage = nil\n'''
if reload_anchor not in browser:
    raise SystemExit("3105 app research patch: reload start anchor changed")
browser = browser.replace(reload_anchor, reload_replacement, 1)

final_anchor = '''            DispatchQueue.main.async {\n                apps = result\n                isLoading = false\n                isResolving = false\n                if result.isEmpty {\n                    errorMessage = emptyMessage\n                }\n            }\n'''
final_replacement = '''            let apiIDs = Set(apiApps.map(\\.bundleID))\n            let mcmIDs = Set(mcmApps.map(\\.bundleID))\n            let launchServiceIDs = Set(launchServicesIdentifiers)\n            let researchIDs = Set(ContainerStore.researchAppIdentifiers)\n            let inferredIDs = Set(inferredFilesystemApps.map(\\.bundleID))\n\n            DispatchQueue.main.async {\n                apps = result\n                // The research catalog starts from the exact resolved result.\n                // Candidate-only metadata is added lazily only for opt-in modes.\n                researchCandidates = result\n                installedAPIBundleIDs = apiIDs\n                mcmBundleIDs = mcmIDs\n                launchServicesBundleIDs = launchServiceIDs\n                researchBundleIDs = researchIDs\n                filesystemBundleIDs = inferredIDs\n                launchServicesCandidateIdentifiers = launchServicesIdentifiers\n                isLoading = false\n                isResolving = false\n                if result.isEmpty {\n                    errorMessage = emptyMessage\n                }\n                if appViewMode.requiresResearchCatalog {\n                    loadResearchCatalogIfNeeded()\n                }\n            }\n'''
if final_anchor not in browser:
    raise SystemExit("3105 app research patch: final result anchor changed")
browser = browser.replace(final_anchor, final_replacement, 1)

reload_method_anchor = '''    private func reload() {\n'''
helper_methods = '''    private func sortedApps(_ source: [InstalledApp]) -> [InstalledApp] {\n        source.sorted { lhs, rhs in\n            switch appSortOrder {\n            case .name:\n                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)\n                if comparison != .orderedSame { return comparison == .orderedAscending }\n                return lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID) == .orderedAscending\n            case .bundleID:\n                let comparison = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)\n                if comparison != .orderedSame { return comparison == .orderedAscending }\n                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending\n            case .discovery:\n                let left = discoverySummary(for: lhs)\n                let right = discoverySummary(for: rhs)\n                let comparison = left.localizedCaseInsensitiveCompare(right)\n                if comparison != .orderedSame { return comparison == .orderedAscending }\n                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending\n            }\n        }\n    }\n\n    private func isInternalHiddenCandidate(_ app: InstalledApp) -> Bool {\n        let identifier = app.bundleID.lowercased()\n        let name = app.displayName.lowercased()\n        if AppBrowserResearchClassifier.matchesHiddenMarker(identifier) ||\n            AppBrowserResearchClassifier.matchesHiddenMarker(name) {\n            return true\n        }\n        guard identifier.hasPrefix("com.apple.") else { return false }\n        return !installedAPIBundleIDs.contains(app.bundleID) &&\n            (launchServicesBundleIDs.contains(app.bundleID) ||\n             mcmBundleIDs.contains(app.bundleID) ||\n             app.containerPath.isEmpty)\n    }\n\n    private func isSystemServiceCandidate(_ app: InstalledApp) -> Bool {\n        let identifier = app.bundleID.lowercased()\n        let name = app.displayName.lowercased()\n        guard identifier.hasPrefix("com.apple.") else { return false }\n        return app.containerPath.isEmpty ||\n            AppBrowserResearchClassifier.matchesServiceMarker(identifier) ||\n            AppBrowserResearchClassifier.matchesServiceMarker(name)\n    }\n\n    private func discoverySummary(for app: InstalledApp) -> String {\n        var tags: [String] = []\n        if installedAPIBundleIDs.contains(app.bundleID) { tags.append("API") }\n        if mcmBundleIDs.contains(app.bundleID) { tags.append("MCM") }\n        if launchServicesBundleIDs.contains(app.bundleID) { tags.append("LS") }\n        if researchBundleIDs.contains(app.bundleID) { tags.append("RESEARCH") }\n        if filesystemBundleIDs.contains(app.bundleID) { tags.append("FS") }\n        tags.append(app.containerPath.isEmpty ? "NO DATA CONTAINER" : "DATA")\n        return tags.joined(separator: " · ")\n    }\n\n    private func loadResearchCatalogIfNeeded() {\n        guard appViewMode.requiresResearchCatalog,\n              !isResolving,\n              !isResearchCatalogLoading,\n              !didLoadResearchCatalog,\n              !launchServicesCandidateIdentifiers.isEmpty else {\n            return\n        }\n\n        isResearchCatalogLoading = true\n        let revision = researchCatalogRevision\n        let baseApps = researchCandidates\n        let existingIDs = Set(baseApps.map(\\.bundleID))\n        let launchServiceCandidates = launchServicesCandidateIdentifiers\n        let installedIDs = installedAPIBundleIDs\n        let researchIDs = Array(researchBundleIDs)\n\n        DispatchQueue.global(qos: .utility).async {\n            let candidateIDs = AppBrowserResearchClassifier.researchCandidateIdentifiers(\n                research: researchIDs,\n                launchServices: launchServiceCandidates,\n                installedAPI: installedIDs\n            )\n            var additions: [InstalledApp] = []\n            var seen = existingIDs\n\n            for bundleID in candidateIDs where seen.insert(bundleID).inserted {\n                let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]\n                guard rawInfo["found"] as? Bool == true else { continue }\n                additions.append(InstalledApp(\n                    bundleID: bundleID,\n                    name: rawInfo["name"] as? String ?? bundleID,\n                    containerPath: "",\n                    version: rawInfo["version"] as? String ?? "",\n                    icon: nil\n                ))\n            }\n\n            let merged = baseApps + additions\n            DispatchQueue.main.async {\n                guard revision == researchCatalogRevision else { return }\n                researchCandidates = merged\n                isResearchCatalogLoading = false\n                didLoadResearchCatalog = true\n                log("browser: research catalog added \\(additions.count) candidate-only installed apps")\n            }\n        }\n    }\n\n    private func reload() {\n'''
if reload_method_anchor not in browser:
    raise SystemExit("3105 app research patch: helper insertion anchor changed")
browser = browser.replace(reload_method_anchor, helper_methods, 1)

enum_anchor = '''private enum AppBrowserOverlayState: Equatable {\n'''
enums_and_classifier = '''private enum AppBrowserViewMode: String, CaseIterable, Identifiable {\n    case `default` = "default"\n    case userApps = "user-apps"\n    case appleApps = "apple-apps"\n    case internalHidden = "internal-hidden"\n    case systemServices = "system-services"\n    case unresolvedInteresting = "unresolved-interesting"\n\n    var id: String { rawValue }\n\n    var title: String {\n        switch self {\n        case .default: return "Default"\n        case .userApps: return "User Apps"\n        case .appleApps: return "Apple Apps"\n        case .internalHidden: return "Internal & Hidden"\n        case .systemServices: return "System / Services"\n        case .unresolvedInteresting: return "Unresolved / Interesting"\n        }\n    }\n\n    var requiresResearchCatalog: Bool {\n        switch self {\n        case .internalHidden, .systemServices, .unresolvedInteresting:\n            return true\n        case .default, .userApps, .appleApps:\n            return false\n        }\n    }\n}\n\nprivate enum AppBrowserSortOrder: String, CaseIterable, Identifiable {\n    case name\n    case bundleID = "bundle-id"\n    case discovery\n\n    var id: String { rawValue }\n\n    var title: String {\n        switch self {\n        case .name: return "Name"\n        case .bundleID: return "Bundle ID"\n        case .discovery: return "Discovery Source"\n        }\n    }\n}\n\nprivate enum AppBrowserResearchClassifier {\n    private static let hiddenMarkers = [\n        "internal", "diagnostic", "factory", "demo", "shelf", "field",\n        "seed", "prototype", "debug", "test", "developer", "setup",\n        "restore", "posterboard", "preferences", "settings", "incall",\n        "springboard", "backboard", "managed", "carrier", "provision"\n    ]\n\n    private static let serviceMarkers = [\n        "daemon", "service", "agent", "plugin", "extension", "springboard",\n        "backboard", "containermanager", "installd", "trustd", "securityd",\n        "mobileactivation", "diagnostic", "factory", "managed"\n    ]\n\n    static func matchesHiddenMarker(_ value: String) -> Bool {\n        let lower = value.lowercased()\n        return hiddenMarkers.contains { lower.contains($0) }\n    }\n\n    static func matchesServiceMarker(_ value: String) -> Bool {\n        let lower = value.lowercased()\n        return serviceMarkers.contains { lower.contains($0) }\n    }\n\n    static func researchCandidateIdentifiers(\n        research: [String],\n        launchServices: [String],\n        installedAPI: Set<String>,\n        limit: Int = 384\n    ) -> [String] {\n        var result: [String] = []\n        var seen = Set<String>()\n\n        func append(_ raw: String) {\n            guard result.count < limit else { return }\n            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)\n            guard identifier.lowercased().hasPrefix("com.apple."),\n                  ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier),\n                  seen.insert(identifier).inserted else {\n                return\n            }\n            result.append(identifier)\n        }\n\n        // Known research targets and obvious internal/service names are checked\n        // first, then a bounded sample of other Apple LaunchServices candidates\n        // absent from the normal installed-app API. Each candidate is still\n        // required to resolve through LSApplicationProxy before it is displayed.\n        for identifier in research where matchesHiddenMarker(identifier) {\n            append(identifier)\n        }\n        for identifier in launchServices where matchesHiddenMarker(identifier) || matchesServiceMarker(identifier) {\n            append(identifier)\n        }\n        for identifier in launchServices\n            where !installedAPI.contains(identifier) && identifier.lowercased().hasPrefix("com.apple.") {\n            append(identifier)\n            if result.count >= limit { break }\n        }\n        return result\n    }\n}\n\nprivate enum AppBrowserOverlayState: Equatable {\n'''
if enum_anchor not in browser:
    raise SystemExit("3105 app research patch: enum insertion anchor changed")
browser = browser.replace(enum_anchor, enums_and_classifier, 1)

# Fail closed if the current default path was accidentally broadened. The new
# research modes must coexist with the upstream presentation policy, not replace it.
required = [
    marker,
    'case internalHidden = "internal-hidden"',
    'Picker("View", selection: $appViewMode)',
    'Picker("Sort", selection: $appSortOrder)',
    'if appViewMode == .default && appSortOrder == .name',
    'ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)',
    'AppBrowserResearchClassifier.researchCandidateIdentifiers',
    'rawInfo["found"] as? Bool == true',
    'Label("Repackage as IPA"',
]
for needle in required:
    if needle not in browser:
        raise SystemExit(f"3105 app research patch contract failed: {needle}")

browser_path.write_text(browser, encoding="utf-8")
PY

grep -Fq 'FILZA_3105_APP_RESEARCH_SORT_V1' "$BROWSER"
grep -Fq 'case internalHidden = "internal-hidden"' "$BROWSER"
grep -Fq 'Picker("View", selection: $appViewMode)' "$BROWSER"
grep -Fq 'Picker("Sort", selection: $appSortOrder)' "$BROWSER"
grep -Fq 'if appViewMode == .default && appSortOrder == .name' "$BROWSER"
grep -Fq 'ContainerPresentationPolicy.shouldShow(bundleID: $0.bundleID)' "$BROWSER"
grep -Fq 'AppBrowserResearchClassifier.researchCandidateIdentifiers' "$BROWSER"
grep -Fq 'Label("Repackage as IPA"' "$BROWSER"

echo "Patched 3105 Apps Manager with opt-in internal/hidden research views and sorting"
