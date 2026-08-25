import SwiftUI
import UIKit

struct RepositorySourcesView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var showAddSource = false
    @State private var showSimulatedSourceDetail = false
    @State private var simulatedSourceDetailGate = OneShotPresentationGate()

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.sources.isEmpty {
                    Section {
                        emptyState
                    }
                } else {
                    Section {
                        ForEach(store.sources) { source in
                            NavigationLink {
                                RepositorySourceDetailView(sourceID: source.id)
                            } label: {
                                RepositorySourceRow(source: source)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.removeSource(source)
                                } label: {
                                    Label(
                                        language.text("repository.remove_source"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                            .contextMenu {
                                sourceActions(source)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("repository.sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(language.text("repository.add_source"))
                }
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .refreshable {
                await store.refreshAllAndWait()
            }
            .onAppear {
                store.refreshAllIfNeeded()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--simulate-source-detail"),
                   simulatedSourceDetailGate.claim() {
                    DispatchQueue.main.async {
                        showSimulatedSourceDetail = true
                    }
                }
#endif
            }
            .sheet(isPresented: $showAddSource) {
                AddRepositorySourceView()
            }
            .navigationDestination(isPresented: $showSimulatedSourceDetail) {
                if let sourceID = store.sources.first?.id {
                    RepositorySourceDetailView(sourceID: sourceID)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("repository.no_sources_title"))
                .font(.headline)
            Text(language.text("repository.no_sources_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(language.text("repository.add_source")) {
                showAddSource = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    @ViewBuilder
    private func sourceActions(_ source: RepositorySource) -> some View {
        Button {
            store.refresh(source)
        } label: {
            Label(
                language.text("repository.refresh_source"),
                systemImage: "arrow.clockwise"
            )
        }
        Button {
            UIPasteboard.general.string = source.manifestURL.absoluteString
        } label: {
            Label(
                language.text("repository.copy_link"),
                systemImage: "doc.on.doc"
            )
        }
        Button(role: .destructive) {
            store.removeSource(source)
        } label: {
            Label(
                language.text("repository.remove_source"),
                systemImage: "trash"
            )
        }
    }
}

private struct RepositorySourceRow: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    let source: RepositorySource

    var body: some View {
        HStack(spacing: 12) {
            RepositorySourceIcon(
                repository: store.repository(for: source.id),
                fallbackText: store.repository(for: source.id)?.name
                    ?? source.manifestURL.host
                    ?? "3105"
            )
            Text(
                store.repository(for: source.id)?.name
                    ?? source.manifestURL.host
                    ?? language.text("repository.unknown_source")
            )
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private struct RepositorySourceStatus: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    let source: RepositorySource

    @ViewBuilder
    var body: some View {
        switch store.state(for: source.id) {
        case .idle:
            Text(language.text("repository.not_refreshed"))
                .foregroundStyle(.secondary)
        case .loading:
            Label(
                language.text("repository.refreshing"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.secondary)
        case .loaded:
            Text(language.text(
                "repository.package_count",
                Int64(store.repository(for: source.id)?.packages.count ?? 0)
            ))
            .foregroundStyle(.secondary)
        case .failed(let error):
            Label(
                language.text(error.localizationKey),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .lineLimit(2)
        }
    }
}

private struct RepositorySourceDetailView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var showSimulatedPackageDetail = false
    @State private var simulatedPackageDetailGate = OneShotPresentationGate()
    let sourceID: UUID

    private var source: RepositorySource? {
        store.sources.first { $0.id == sourceID }
    }

    private var repository: PackageRepository? {
        store.repository(for: sourceID)
    }

    private var records: [RepositoryPackageRecord] {
        guard let source, let repository else { return [] }
        return repository.packages.map {
            RepositoryPackageRecord(
                sourceID: source.id,
                sourceName: repository.name,
                sourceURL: repository.sourceURL,
                package: $0
            )
        }
    }

    private var tagGroups: [RepositoryTagGroup] {
        PackageRepositoryTagIndex.groups(for: repository?.packages ?? [])
    }

    var body: some View {
        List {
            sourceHeader

            if let source, store.state(for: source.id) == .loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(language.text("repository.refreshing"))
                    }
                }
            } else if records.isEmpty {
                Section {
                    Text(language.text("repository.source_empty"))
                        .foregroundStyle(.secondary)
                }
            } else {
                packageGroups
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(
            repository?.name
                ?? source?.manifestURL.host
                ?? language.text("repository.unknown_source")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refreshSource) {
                    if let source, store.state(for: source.id) == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(source == nil || source.map {
                    store.state(for: $0.id) == .loading
                } == true)
                .accessibilityLabel(language.text("repository.refresh_source"))
            }
        }
        .onAppear {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--simulate-package-detail"),
               simulatedPackageDetailGate.claim() {
                DispatchQueue.main.async {
                    showSimulatedPackageDetail = true
                }
            }
#endif
        }
        .navigationDestination(isPresented: $showSimulatedPackageDetail) {
            if let record = records.first {
                RepositoryPackageDetailView(record: record)
            }
        }
    }

    private var sourceHeader: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                RepositorySourceIcon(
                    repository: repository,
                    fallbackText: repository?.name
                        ?? source?.manifestURL.host
                        ?? "3105"
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(repository?.name
                        ?? source?.manifestURL.host
                        ?? language.text("repository.unknown_source"))
                        .font(.body.weight(.semibold))
                    if let summary = repository?.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let source {
                        RepositorySourceStatus(source: source)
                            .font(.caption)
                    }
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func refreshSource() {
        if let current = store.sources.first(where: { $0.id == sourceID }) {
            store.refresh(current)
        }
    }

    private var packageGroups: some View {
        Section {
            NavigationLink {
                RepositoryTagPackagesView(
                    title: language.text("repository.all_source_packages"),
                    records: records
                )
            } label: {
                RepositoryTagRow(
                    name: language.text("repository.all_source_packages"),
                    count: records.count,
                    package: records.first?.package
                )
            }

            ForEach(tagGroups) { group in
                NavigationLink {
                    RepositoryTagPackagesView(
                        title: group.name,
                        records: records.filter { record in
                            group.packages.contains {
                                $0.identifier == record.package.identifier
                            }
                        }
                    )
                } label: {
                    RepositoryTagRow(
                        name: group.name,
                        count: group.packages.count,
                        package: group.packages.first
                    )
                }
            }
        } header: {
            Text(language.text("repository.source_tags"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

private struct RepositoryTagRow: View {
    @Environment(\.appLanguage) private var language
    let name: String
    let count: Int
    let package: RepositoryPackage?

    var body: some View {
        HStack(spacing: 12) {
            if let package {
                RepositoryPackageIcon(package: package, size: 34)
            } else {
                AppRowIcon(systemName: "tag.fill", frameSize: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(language.text("repository.package_count", Int64(count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct RepositoryTagPackagesView: View {
    let title: String
    let records: [RepositoryPackageRecord]

    var body: some View {
        List(records) { record in
            NavigationLink {
                RepositoryPackageDetailView(record: record)
            } label: {
                RepositoryPackageRow(record: record)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
