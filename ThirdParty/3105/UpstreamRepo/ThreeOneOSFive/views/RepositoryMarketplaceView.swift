import SwiftUI
import UIKit

struct LegacyRepositoryExploreView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var activeTool: BuiltInTool?

    let wallpapersSupported: Bool
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var featuredPackages: [RepositoryPackageRecord] {
        repositoryStore.packages.filter(\.package.isFeatured)
    }

    private var regularPackages: [RepositoryPackageRecord] {
        let featuredIDs = Set(featuredPackages.map(\.id))
        return repositoryStore.packages.filter { !featuredIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                builtInToolsSection

                if repositoryStore.packages.isEmpty {
                    marketplaceEmptySection
                } else {
                    if !featuredPackages.isEmpty {
                        packageSection(
                            titleKey: "repository.featured",
                            packages: featuredPackages
                        )
                    }
                    if !regularPackages.isEmpty {
                        packageSection(
                            titleKey: "repository.all_packages",
                            packages: regularPackages
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("repository.explore"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .refreshable {
                await repositoryStore.refreshAllAndWait()
            }
            .onAppear {
                repositoryStore.refreshAllIfNeeded()
            }
            .sheet(item: $activeTool) { tool in
                switch tool {
                case .cleaner:
                    CleanerView()
                case .wallpaper:
                    WallpaperLabView()
                }
            }
            .navigationDestination(for: RepositoryPackageRecord.self) { record in
                RepositoryPackageDetailView(record: record)
            }
        }
    }

    private var builtInToolsSection: some View {
        Section {
            if cleanerEnabled {
                builtInToolButton(
                    .cleaner,
                    titleKey: "tab.cleaner",
                    subtitleKey: "repository.cleaner_subtitle",
                    systemImage: "sparkles"
                )
            }
            if wallpapersSupported {
                builtInToolButton(
                    .wallpaper,
                    titleKey: "tab.wallpapers",
                    subtitleKey: "repository.wallpaper_subtitle",
                    systemImage: wallpaperSymbol
                )
            }
            if !cleanerEnabled && !wallpapersSupported {
                Text(language.text("repository.tools_disabled"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(language.text("repository.built_in_tools"))
        } footer: {
            Text(language.text("repository.tools_footer"))
        }
    }

    private func builtInToolButton(
        _ tool: BuiltInTool,
        titleKey: String,
        subtitleKey: String,
        systemImage: String
    ) -> some View {
        Button {
            activeTool = tool
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: systemImage)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text(titleKey))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(language.text(subtitleKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(language.text("repository.open_tool_hint"))
    }

    private var marketplaceEmptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                    .foregroundStyle(AppTheme.accent)
                Text(language.text(
                    repositoryStore.sources.isEmpty
                        ? "repository.no_sources_title"
                        : "repository.no_packages_title"
                ))
                .font(.headline)
                Text(language.text(
                    repositoryStore.sources.isEmpty
                        ? "repository.no_sources_message"
                        : "repository.no_packages_message"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func packageSection(
        titleKey: String,
        packages: [RepositoryPackageRecord]
    ) -> some View {
        Section(language.text(titleKey)) {
            ForEach(packages) { record in
                NavigationLink(value: record) {
                    RepositoryPackageRow(record: record)
                }
            }
        }
    }

    private var wallpaperSymbol: String {
        if #available(iOS 18.0, *) {
            return "photo.on.rectangle.angled.fill"
        }
        return "photo.fill.on.rectangle.fill"
    }
}

struct LegacyRepositorySourcesView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var showAddSource = false

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.sources.isEmpty {
                    Section {
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
                } else {
                    Section {
                        ForEach(store.sources) { source in
                            sourceRow(source)
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
                        }
                    } footer: {
                        Text(language.text("repository.sources_footer"))
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
            }
            .sheet(isPresented: $showAddSource) {
                AddRepositorySourceView()
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: RepositorySource) -> some View {
        sourceIdentity(source)
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                store.refresh(source)
            } label: {
                Label(
                    language.text("repository.refresh_source"),
                    systemImage: "arrow.clockwise"
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

    private func sourceIdentity(_ source: RepositorySource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RepositorySourceIcon(
                repository: store.repository(for: source.id),
                fallbackText: source.manifestURL.host ?? "3105"
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    store.repository(for: source.id)?.name
                        ?? source.manifestURL.host
                        ?? language.text("repository.unknown_source")
                )
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                Text(source.manifestURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                sourceStatus(source)
            }
        }
    }

    @ViewBuilder
    private func sourceStatus(_ source: RepositorySource) -> some View {
        switch store.state(for: source.id) {
        case .idle:
            Text(language.text("repository.not_refreshed"))
                .foregroundStyle(.secondary)
        case .loading:
            Label(language.text("repository.refreshing"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .loaded:
            Text(language.text(
                "repository.package_count",
                Int64(store.repository(for: source.id)?.packages.count ?? 0)
            ))
            .foregroundStyle(.secondary)
        case .failed(let error):
            Label(language.text(error.localizationKey), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

struct RepositoryPackageDetailView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @EnvironmentObject private var patchStore: PatchProjectStore
    @State private var isSupportedOSExpanded = false

    let record: RepositoryPackageRecord
    private static let informationSectionID = "repository-package-information"

    private var compatibility: PackageCompatibility {
        PackageCompatibilityEvaluator.evaluate(
            record.package.supportedOS,
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    private var isInstalled: Bool {
        if record.package.kind == .wallpaper {
            return repositoryStore.isInstalled(record)
        }
        guard let packageID = repositoryStore.resolvedPackageID(for: record) else {
            return false
        }
        return patchStore.items.contains { $0.id == packageID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    headerSection
                    if let bannerURL = record.package.bannerURL {
                        bannerSection(url: bannerURL)
                    }
                    descriptionSection
                    if let changelog = record.package.changelog {
                        detailBlock(titleKey: "repository.changelog") {
                            Text(changelog)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    informationSection
                        .id(Self.informationSectionID)
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppTheme.contentCardInset)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                scrollToInformationIfNeeded(using: proxy)
            }
        }
        .navigationTitle(record.package.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scrollToInformationIfNeeded(using proxy: ScrollViewProxy) {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains(
            "--simulate-package-information"
        ) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            proxy.scrollTo(Self.informationSectionID, anchor: .top)
        }
#endif
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    RepositoryPackageIcon(package: record.package, size: 80)
                    packageIdentity
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    RepositoryPackageIcon(package: record.package, size: 80)
                    packageIdentity
                    Spacer(minLength: 0)
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    metadataBadge(
                        record.package.version,
                        systemImage: "tag.fill"
                    )
                    if record.package.isPrivate {
                        metadataBadge(
                            language.text("patch.private"),
                            systemImage: "eye.slash.fill"
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadataBadge(
                        record.package.version,
                        systemImage: "tag.fill"
                    )
                    if record.package.isPrivate {
                        metadataBadge(
                            language.text("patch.private"),
                            systemImage: "eye.slash.fill"
                        )
                    }
                    Spacer(minLength: 0)
                }
            }

            installButton
        }
        .padding(18)
        .background(
            Color(uiColor: .systemBackground),
            in: RoundedRectangle(
                cornerRadius: AppTheme.contentCardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            AppCardBorder()
        }
    }

    private var packageIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.package.name)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(record.package.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(language.text(
                "repository.home_package_meta",
                record.package.author,
                record.sourceName
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var descriptionSection: some View {
        detailBlock(titleKey: "repository.description") {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.package.details ?? record.package.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !record.package.screenshotURLs.isEmpty {
                    Divider()
                    previewGallery
                }
            }
        }
    }

    private var previewGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(
                    Array(record.package.screenshotURLs.enumerated()),
                    id: \.offset
                ) { index, screenshotURL in
                    RepositoryScreenshotPreview(
                        url: screenshotURL,
                        accessibilityLabel: language.text(
                            "repository.preview_number",
                            Int64(index + 1)
                        )
                    )
                }
            }
        }
    }

    private var informationSection: some View {
        detailBlock(titleKey: "repository.information") {
            VStack(spacing: 0) {
                detailRow(
                    label: language.text("repository.version"),
                    value: record.package.version
                )
                detailDivider()
                detailRow(
                    label: language.text("repository.source"),
                    value: record.sourceName
                )
                detailDivider()
                detailRow(
                    label: language.text("patch.author"),
                    value: record.package.author
                )
                if let category = record.package.category {
                    detailDivider()
                    detailRow(
                        label: language.text("repository.category"),
                        value: category
                    )
                }
                detailDivider()
                supportedOSDisclosure
                if let publishedAt = record.package.publishedAt {
                    detailDivider()
                    detailRow(
                        label: language.text("repository.published")
                    ) {
                        Text(publishedAt, style: .date)
                    }
                }
                if record.package.isPrivate {
                    detailDivider()
                    detailRow(label: language.text("patch.privacy")) {
                        Label(
                            language.text("patch.private"),
                            systemImage: "eye.slash.fill"
                        )
                        .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
    }

    private var supportedOSDisclosure: some View {
        DisclosureGroup(isExpanded: $isSupportedOSExpanded) {
            supportedOSInformation
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 4)
        } label: {
            Text(language.text("repository.supported_ios"))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.vertical, 11)
        .accessibilityHint(language.text("repository.supported_ios_hint"))
    }

    private var supportedOSInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(record.package.supportedOS, id: \.self) { range in
                VStack(alignment: .leading, spacing: 2) {
                    Text(supportedOSTitle(for: range))
                    if let builds = range.builds, !builds.isEmpty {
                        Text(language.text(
                            "repository.supported_builds",
                            builds.joined(separator: ", ")
                        ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func supportedOSTitle(for range: PackageOSRange) -> String {
        if range.minimum == range.maximum {
            return language.text("repository.os_version", range.minimum)
        }
        return language.text(
            "repository.os_range",
            range.minimum,
            range.maximum
        )
    }

    private func bannerSection(url: URL) -> some View {
        RepositoryRemoteImage(url: url, cornerRadius: 0)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 7, contentMode: .fit)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: AppTheme.contentCardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                AppCardBorder()
            }
    }

    private func detailBlock<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailSectionHeader(titleKey)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.contentCardPadding)
                .background(
                    Color(uiColor: .systemBackground),
                    in: RoundedRectangle(
                        cornerRadius: AppTheme.contentCardCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    AppCardBorder()
                }
        }
    }

    private func detailRow<Content: View>(
        label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .foregroundStyle(.secondary)
                    value()
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    value()
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline)
        .padding(.vertical, 11)
    }

    private func detailRow(label: String, value: String) -> some View {
        detailRow(label: label) {
            Text(value)
        }
    }

    private func detailDivider() -> some View {
        Divider()
    }

    private var installButton: some View {
        Button {
            repositoryStore.install(record, using: patchStore)
        } label: {
            Group {
                if repositoryStore.isDownloading(record) {
                    elapsedDownloadLabel
                } else if patchStore.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(language.text(
                        installButtonTitleKey
                    ))
                    .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(
            compatibility != .compatible
                || repositoryStore.isDownloading(record)
                || patchStore.isBusy
        )
        .accessibilityHint(language.text("repository.install_footer"))
    }

    private var elapsedDownloadLabel: some View {
        let startedAt = repositoryStore.downloadStartedAt(for: record) ?? Date()
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(language.text(
                    "repository.downloading_elapsed",
                    RepositoryDownloadDurationFormatter.string(
                        elapsedSeconds: context.date.timeIntervalSince(startedAt)
                    )
                ))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    private var installButtonTitleKey: String {
        if isInstalled {
            return "repository.update_package"
        }
        return record.package.kind == .wallpaper
            ? "repository.download_package"
            : "repository.install_package"
    }

    private func detailSectionHeader(_ key: String) -> some View {
        Text(language.text(key))
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private func metadataBadge(
        _ text: String,
        systemImage: String
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
    }
}

struct RepositoryPackageRow: View {
    @Environment(\.appLanguage) private var language
    let record: RepositoryPackageRecord

    var body: some View {
        HStack(spacing: 12) {
            RepositoryPackageIcon(package: record.package, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.package.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(record.package.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(language.text(
                    "repository.by_version",
                    record.package.author,
                    record.package.version
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RepositoryPackageIcon: View {
    @StateObject private var imageLoader = RepositoryImageLoader()
    let package: RepositoryPackage
    let size: CGFloat

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
        .task(id: package.iconURL) {
            guard let iconURL = package.iconURL else { return }
            await imageLoader.load(url: iconURL, maximumPixelSize: 240)
        }
    }

    private var placeholder: some View {
        Image(systemName: package.kind == .wallpaper ? "photo.fill" : "shippingbox.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(AppTheme.accent)
    }
}

struct RepositoryRemoteImage: View {
    @StateObject private var imageLoader = RepositoryImageLoader()
    let url: URL
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if imageLoader.didFail {
                remoteImagePlaceholder(progressVisible: false)
            } else {
                remoteImagePlaceholder(progressVisible: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipped()
        .task(id: url) {
            await imageLoader.load(url: url, maximumPixelSize: 1_440)
        }
    }

    private func remoteImagePlaceholder(progressVisible: Bool) -> some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .overlay {
                if progressVisible {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
    }
}

private struct RepositoryScreenshotPreview: View {
    @StateObject private var imageLoader = RepositoryImageLoader()
    let url: URL
    let accessibilityLabel: String

    private var previewSize: CGSize {
        guard let image = imageLoader.image else {
            return CGSize(width: 280, height: 180)
        }
        let size = RepositoryPreviewLayout.fittedSize(
            pixelWidth: image.size.width,
            pixelHeight: image.size.height,
            maximumWidth: 320,
            maximumHeight: 296
        )
        return CGSize(width: size.width, height: size.height)
    }

    var body: some View {
        ZStack {
            if imageLoader.image == nil {
                Color(uiColor: .secondarySystemFill)
            } else {
                Color(uiColor: .systemBackground)
            }

            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if imageLoader.didFail {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.2), value: previewSize)
        .task(id: url) {
            await imageLoader.load(url: url, maximumPixelSize: 1_200)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct RepositorySourceIcon: View {
    @StateObject private var imageLoader = RepositoryImageLoader()
    let repository: PackageRepository?
    let fallbackText: String

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 38, height: 38)
        .background(AppTheme.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
        .task(id: repository?.iconURL) {
            guard let iconURL = repository?.iconURL else { return }
            await imageLoader.load(url: iconURL, maximumPixelSize: 160)
        }
    }

    private var placeholder: some View {
        Text(String(fallbackText.prefix(1)).uppercased())
            .font(.headline)
            .foregroundStyle(AppTheme.accent)
    }
}

struct AddRepositorySourceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var store: PackageRepositoryStore
    @State private var sourceURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "https://example.com/repo.json",
                        text: $sourceURL
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.done)
                    .onSubmit(add)
                } header: {
                    Text(language.text("repository.source_url"))
                } footer: {
                    Text(language.text("repository.source_url_footer"))
                }
            }
            .navigationTitle(language.text("repository.add_source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("repository.add"), action: add)
                        .fontWeight(.semibold)
                        .disabled(sourceURL.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                }
            }
        }
    }

    private func add() {
        guard !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if store.addSource(rawURL: sourceURL) {
            dismiss()
        }
    }
}

struct AppUtilityToolbar: ToolbarContent {
    let language: AppLanguage
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(action: onOpenSettings) {
                    Label(
                        language.text("settings.title"),
                        systemImage: "gearshape"
                    )
                }
                Button(action: onOpenLogs) {
                    Label(
                        language.text("accessibility.open_logs"),
                        systemImage: "apple.terminal"
                    )
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(language.text("accessibility.open_settings"))
        }
    }
}

private enum BuiltInTool: String, Identifiable {
    case cleaner
    case wallpaper

    var id: String { rawValue }
}

private enum StorePresentationAlert: Identifiable {
    case patch(PatchStoreAlert)
    case repository(RepositoryStoreAlert)

    var id: String {
        switch self {
        case .patch(let alert):
            return "patch:" + alert.id.uuidString
        case .repository(let alert):
            return "repository:" + alert.id.uuidString
        }
    }
}

private struct RepositoryStorePresentationModifier: ViewModifier {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PackageRepositoryStore
    @ObservedObject var patchStore: PatchProjectStore

    func body(content: Content) -> some View {
        content.alert(item: activeAlert) { activeAlert in
            switch activeAlert {
            case .patch(let alert):
                Alert(
                    title: Text(language.text(alert.titleKey)),
                    message: Text(alert.message(language: language)),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            case .repository(let alert):
                Alert(
                    title: Text(language.text(alert.titleKey)),
                    message: Text(language.text(alert.messageKey)),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
        }
    }

    private var activeAlert: Binding<StorePresentationAlert?> {
        Binding(
            get: {
                if let repositoryAlert = store.alert {
                    return .repository(repositoryAlert)
                }
                if let patchAlert = patchStore.alert {
                    return .patch(patchAlert)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if store.alert != nil {
                    store.alert = nil
                } else {
                    patchStore.alert = nil
                }
            }
        )
    }
}

extension View {
    func repositoryStorePresentation(
        _ store: PackageRepositoryStore,
        patchStore: PatchProjectStore
    ) -> some View {
        modifier(
            RepositoryStorePresentationModifier(
                store: store,
                patchStore: patchStore
            )
        )
    }
}
