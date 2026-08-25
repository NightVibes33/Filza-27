import Combine
import Foundation

struct RepositoryStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
}

@MainActor
final class PackageRepositoryStore: ObservableObject {
    @Published private(set) var sources: [RepositorySource]
    @Published private(set) var repositories: [UUID: PackageRepository] = [:]
    @Published private(set) var sourceStates: [UUID: RepositorySourceState] = [:]
    @Published private(set) var downloadingPackageKeys = Set<String>()
    @Published private(set) var downloadStartedAtByPackageKey: [String: Date] = [:]
    @Published var alert: RepositoryStoreAlert?
    @Published private var catalogSyncOperations = 0

    private static let storageKey = "repository.sources.v1"
    private static let resolutionStorageKey = "repository.package_resolutions.v1"
    private let defaults: UserDefaults
    private var resolutionIndex: RepositoryPackageResolutionIndex
    private var refreshedThisLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.resolutionStorageKey),
           let decoded = try? JSONDecoder().decode(
               RepositoryPackageResolutionIndex.self,
               from: data
           ) {
            resolutionIndex = decoded
        } else {
            resolutionIndex = RepositoryPackageResolutionIndex()
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([RepositorySource].self, from: data) {
            sources = decoded
        } else {
            sources = []
        }
        for source in sources {
            sourceStates[source.id] = .idle
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-wallpaper-repository") {
            installSimulatorWallpaperRepository()
        } else if ProcessInfo.processInfo.arguments.contains("--simulate-repository") {
            installSimulatorPreviewRepository()
        }
#endif
    }

    var packages: [RepositoryPackageRecord] {
        sources.flatMap { source -> [RepositoryPackageRecord] in
            guard let repository = repositories[source.id] else {
                return []
            }
            return repository.packages.map {
                RepositoryPackageRecord(
                    sourceID: source.id,
                    sourceName: repository.name,
                    sourceURL: repository.sourceURL,
                    package: $0
                )
            }
        }
        .sorted {
            if $0.package.isFeatured != $1.package.isFeatured {
                return $0.package.isFeatured && !$1.package.isFeatured
            }
            return $0.package.name.localizedCaseInsensitiveCompare($1.package.name)
                == .orderedAscending
        }
    }

    var isRefreshing: Bool {
        catalogSyncOperations > 0 || sourceStates.values.contains(.loading)
    }

    func repository(for sourceID: UUID) -> PackageRepository? {
        repositories[sourceID]
    }

    func state(for sourceID: UUID) -> RepositorySourceState {
        sourceStates[sourceID] ?? .idle
    }

    func resolvedPackageID(for record: RepositoryPackageRecord) -> UUID? {
        resolutionIndex.packageID(
            sourceURL: record.sourceURL,
            packageIdentifier: record.package.identifier
        )
    }

    @discardableResult
    func addSource(rawURL: String) -> Bool {
        do {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = URL(string: trimmed) else {
                throw PackageRepositoryError.insecureURL
            }
            let url = try PackageRepositoryURLPolicy.validate(candidate)
            guard !sources.contains(where: {
                $0.manifestURL.absoluteString.caseInsensitiveCompare(url.absoluteString)
                    == .orderedSame
            }) else {
                throw PackageRepositoryError.sourceAlreadyExists
            }
            let source = RepositorySource(manifestURL: url)
            sources.append(source)
            sourceStates[source.id] = .idle
            persist()
            refresh(source)
            return true
        } catch let error as PackageRepositoryError {
            present(error)
            return false
        } catch {
            present(.insecureURL)
            return false
        }
    }

    func removeSource(_ source: RepositorySource) {
        sources.removeAll { $0.id == source.id }
        repositories[source.id] = nil
        sourceStates[source.id] = nil
        persist()
    }

    func refreshAllIfNeeded() {
        guard !refreshedThisLaunch else { return }
        refreshedThisLaunch = true
        Task { [weak self] in
            guard let self else { return }
            await self.synchronizeDefaultSources()
            self.refreshStoredSources()
        }
    }

    func refreshAll() {
        Task { [weak self] in
            guard let self else { return }
            await self.synchronizeDefaultSources()
            self.refreshStoredSources()
        }
    }

    func refreshAllAndWait() async {
        await synchronizeDefaultSources()
        refreshStoredSources()
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func refreshStoredSources() {
        for source in sources {
            refresh(source)
        }
    }

    private func synchronizeDefaultSources() async {
        catalogSyncOperations += 1
        defer { catalogSyncOperations -= 1 }
        do {
            let catalogURLs = try await PackageRepositoryNetworkClient
                .loadSourceCatalog(from: PackageRepositoryDefaults.catalogURL)
            let existingCount = sources.count
            let merged = RepositorySourceMergePolicy.merge(
                existing: sources,
                catalogURLs: catalogURLs
            )
            guard merged.count > existingCount else {
                log(
                    "repository: default catalog synced " +
                    "sources=\(catalogURLs.count) added=0"
                )
                return
            }

            sources = merged
            for source in sources.dropFirst(existingCount) {
                sourceStates[source.id] = .idle
            }
            persist()
            log(
                "repository: default catalog synced " +
                "sources=\(catalogURLs.count) added=\(merged.count - existingCount)"
            )
        } catch let error as PackageRepositoryError {
            log("repository: default catalog unavailable \(error)")
        } catch {
            log("repository: default catalog unavailable")
        }
    }

    func refresh(_ source: RepositorySource) {
        guard state(for: source.id) != .loading else {
            return
        }
        sourceStates[source.id] = .loading
        Task {
            do {
                let repository = try await PackageRepositoryNetworkClient.loadRepository(
                    from: source.manifestURL
                )
                repositories[source.id] = repository
                sourceStates[source.id] = .loaded(Date())
                log(
                    "repository: loaded \(repository.identifier) " +
                    "packages=\(repository.packages.count)"
                )
            } catch let error as PackageRepositoryError {
                repositories[source.id] = nil
                sourceStates[source.id] = .failed(error)
                log("repository: failed \(source.manifestURL.host ?? "unknown") \(error)")
            } catch {
                repositories[source.id] = nil
                sourceStates[source.id] = .failed(.sourceUnavailable)
                log("repository: failed \(source.manifestURL.host ?? "unknown")")
            }
        }
    }

    func install(
        _ record: RepositoryPackageRecord,
        using patchStore: PatchProjectStore
    ) {
        let compatibility = PackageCompatibilityEvaluator.evaluate(
            record.package.supportedOS,
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
        guard compatibility == .compatible else {
            present(.incompatiblePackage)
            return
        }
        guard !downloadingPackageKeys.contains(record.id) else {
            return
        }
        downloadStartedAtByPackageKey[record.id] = Date()
        downloadingPackageKeys.insert(record.id)

        Task {
            defer {
                downloadingPackageKeys.remove(record.id)
                downloadStartedAtByPackageKey[record.id] = nil
            }
            do {
                switch record.package.kind {
                case .patch:
                    let data = try await PackageRepositoryNetworkClient.download(
                        record.package
                    )
                    let summary = try PatchPackageCodec.inspect(data)
                    resolutionIndex.record(
                        summary.packageID,
                        sourceURL: record.sourceURL,
                        packageIdentifier: record.package.identifier
                    )
                    persistResolutionIndex()
                    let origin = PatchPackageOrigin(
                        repositoryName: record.sourceName,
                        repositoryURL: record.sourceURL,
                        packageIdentifier: record.package.identifier
                    )
                    guard patchStore.importPackage(
                        data: data,
                        password: record.package.sharedPassword,
                        origin: origin
                    ) else {
                        throw PackageRepositoryError.importUnavailable
                    }
                    log(
                        "repository: handed off \(record.package.identifier) " +
                            "to patch import"
                    )
                case .wallpaper:
                    let packageURL = try await PackageRepositoryNetworkClient
                        .downloadWallpaper(record.package)
                    defer { try? FileManager.default.removeItem(at: packageURL) }
                    try await Task.detached(priority: .userInitiated) {
                        _ = try WallpaperPackageStore.importPackage(
                            from: packageURL,
                            displayName: record.package.name,
                            repositoryIdentity: record.repositoryIdentity
                        )
                    }.value
                    alert = RepositoryStoreAlert(
                        titleKey: "wallpaper.import_done_title",
                        messageKey: "repository.wallpaper_imported"
                    )
                    log(
                        "repository: imported wallpaper " +
                            record.package.identifier
                    )
                }
            } catch let error as PackageRepositoryError {
                present(error)
            } catch let error as PatchPackageError {
                patchStore.presentImportError(error)
            } catch let error as WallpaperLabError {
                present(error)
            } catch {
                present(.sourceUnavailable)
            }
        }
    }

    func isDownloading(_ record: RepositoryPackageRecord) -> Bool {
        downloadingPackageKeys.contains(record.id)
    }

    func downloadStartedAt(for record: RepositoryPackageRecord) -> Date? {
        downloadStartedAtByPackageKey[record.id]
    }

    func isInstalled(_ record: RepositoryPackageRecord) -> Bool {
        switch record.package.kind {
        case .patch:
            return false
        case .wallpaper:
            return WallpaperPackageStore.contains(
                repositoryIdentity: record.repositoryIdentity
            )
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func persistResolutionIndex() {
        guard let data = try? JSONEncoder().encode(resolutionIndex) else { return }
        defaults.set(data, forKey: Self.resolutionStorageKey)
    }

    private func present(_ error: PackageRepositoryError) {
        alert = RepositoryStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey
        )
    }

    private func present(_ error: WallpaperLabError) {
        alert = RepositoryStoreAlert(
            titleKey: "wallpaper.operation_failed",
            messageKey: error.localizationKey
        )
    }

#if targetEnvironment(simulator)
    private func installSimulatorPreviewRepository() {
        let sourceURL = URL(string: "https://example.com/3105/repo.json")!
        let source = RepositorySource(manifestURL: sourceURL)
        let ranges = [
            PackageOSRange(minimum: "17.0", maximum: "18.7.1", builds: nil),
            PackageOSRange(minimum: "26.0", maximum: "26.6.1", builds: nil),
            PackageOSRange(minimum: "27.0", maximum: "27.0", builds: ["24A5390f"])
        ]
        let previewPackages = [
            RepositoryPackage(
                identifier: "clean-layout",
                kind: .patch,
                name: "Clean Layout",
                author: "YangJiii",
                version: "1.2.0",
                summary: "A compact layout patch for a cleaner app interface.",
                details: "Simulator preview package used to verify marketplace layout.",
                category: "Customization",
                tags: ["Customization", "Layout", "Featured"],
                publishedAt: ISO8601DateFormatter().date(
                    from: "2026-08-21T08:00:00Z"
                ),
                iconURL: nil,
                bannerURL: nil,
                screenshotURLs: [
                    URL(string: "https://example.com/previews/clean-layout-1.png")!,
                    URL(string: "https://example.com/previews/clean-layout-2.png")!,
                    URL(string: "https://example.com/previews/clean-layout-3.png")!
                ],
                downloadURL: URL(string: "https://example.com/clean-layout.3105")!,
                sha256: String(repeating: "a", count: 64),
                expectedSize: nil,
                supportedOS: ranges,
                changelog: "Improved spacing and added iOS 27 metadata.",
                isFeatured: true,
                isPrivate: false,
                sharedPassword: nil
            ),
            RepositoryPackage(
                identifier: "profile-switcher",
                kind: .patch,
                name: "Profile Switcher",
                author: "3105 Community",
                version: "1.0.0",
                summary: "A portable workspace example with multiple bundle targets.",
                details: nil,
                category: "Utilities",
                tags: ["Utilities", "Profiles"],
                publishedAt: ISO8601DateFormatter().date(
                    from: "2026-08-18T08:00:00Z"
                ),
                iconURL: nil,
                bannerURL: nil,
                screenshotURLs: [],
                downloadURL: URL(string: "https://example.com/profile-switcher.3105")!,
                sha256: String(repeating: "b", count: 64),
                expectedSize: nil,
                supportedOS: ranges,
                changelog: nil,
                isFeatured: false,
                isPrivate: false,
                sharedPassword: nil
            )
        ]
        sources = [source]
        repositories[source.id] = PackageRepository(
            identifier: "com.yangjiii.preview",
            name: "3105 Preview",
            summary: "Simulator-only marketplace preview",
            iconURL: nil,
            sourceURL: sourceURL,
            packages: previewPackages
        )
        sourceStates[source.id] = .loaded(Date())
        refreshedThisLaunch = true
    }

    private func installSimulatorWallpaperRepository() {
        let revision = "f04c0a8e81c328201ad7769fac16b907ce905035"
        let sourceURL = URL(
            string: "https://raw.githubusercontent.com/YangJiiii/3105-repo/main/" +
                "repositories/demo/repo.json"
        )!
        let previewURL = URL(
            string: "https://raw.githubusercontent.com/SerStars/" +
                "Nugget-Wallpapers/\(revision)/previews/custom/gifs/Cipher.gif"
        )!
        let downloadURL = URL(
            string: "https://raw.githubusercontent.com/SerStars/" +
                "Nugget-Wallpapers/\(revision)/wallpapers/custom/Cipher.tendies"
        )!
        let source = RepositorySource(manifestURL: sourceURL)
        let ranges = [
            PackageOSRange(minimum: "17.0", maximum: "18.7.1", builds: nil),
            PackageOSRange(minimum: "26.0", maximum: "26.6.1", builds: nil),
            PackageOSRange(
                minimum: "27.0",
                maximum: "27.0",
                builds: ["24A5355q", "24A5370h", "24A5380h", "24A5390f"]
            )
        ]
        let package = RepositoryPackage(
            identifier: "nugget-custom-113",
            kind: .wallpaper,
            name: "Cipher",
            author: "@mightycooldude12",
            version: "1.0.0",
            summary: "Decoding...",
            details: "Decoding...\n\nNguồn: SerStars/Nugget-Wallpapers (GPL-3.0).",
            category: "Wallpaper",
            tags: ["Wallpaper", "Custom"],
            publishedAt: nil,
            iconURL: previewURL,
            bannerURL: nil,
            screenshotURLs: [previewURL],
            downloadURL: downloadURL,
            sha256: nil,
            expectedSize: nil,
            supportedOS: ranges,
            changelog: nil,
            isFeatured: false,
            isPrivate: false,
            sharedPassword: nil
        )
        sources = [source]
        repositories[source.id] = PackageRepository(
            identifier: "com.yangjiii.3105",
            name: "3105 Repository",
            summary: "Nguồn chính thức cho tweak và wallpaper của 3105.",
            iconURL: nil,
            sourceURL: sourceURL,
            packages: [package]
        )
        sourceStates[source.id] = .loaded(Date())
        refreshedThisLaunch = true
    }
#endif
}

private final class PackageRepositoryRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? PackageRepositoryURLPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum PackageRepositoryNetworkClient {
    static func loadSourceCatalog(from catalogURL: URL) async throws -> [URL] {
        let trustedURL = try PackageRepositoryURLPolicy.validate(catalogURL)
        let download = try await downloadFile(
            from: trustedURL,
            maximumBytes: PackageRepositoryLimits.maximumCatalogBytes
        )
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
        return try PackageRepositoryCatalogValidator.decode(
            data,
            catalogURL: download.finalURL
        )
    }

    static func loadRepository(from sourceURL: URL) async throws -> PackageRepository {
        let trustedURL = try PackageRepositoryURLPolicy.validate(sourceURL)
        let download = try await downloadFile(
            from: trustedURL,
            maximumBytes: PackageRepositoryLimits.maximumManifestBytes
        )
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
        return try PackageRepositoryValidator.decode(
            data,
            sourceURL: download.finalURL
        )
    }

    static func download(_ package: RepositoryPackage) async throws -> Data {
        guard package.kind == .patch else {
            throw PackageRepositoryError.invalidPackage
        }
        let fileURL = try await verifiedDownload(package, maximumBytes: nil)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    static func downloadWallpaper(_ package: RepositoryPackage) async throws -> URL {
        guard package.kind == .wallpaper else {
            throw PackageRepositoryError.invalidPackage
        }
        return try await verifiedDownload(
            package,
            maximumBytes: Int(WallpaperLabLimits.maximumArchiveBytes)
        )
    }

    private static func verifiedDownload(
        _ package: RepositoryPackage,
        maximumBytes: Int?
    ) async throws -> URL {
        let download = try await downloadFile(
            from: package.downloadURL,
            maximumBytes: maximumBytes
        )
        do {
            let values = try download.fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true else {
                throw PackageRepositoryError.sourceUnavailable
            }
            if let expectedSize = package.expectedSize {
                guard let fileSize = values.fileSize,
                      fileSize >= 0,
                      UInt64(fileSize) == expectedSize else {
                    throw PackageRepositoryError.checksumMismatch
                }
            }
            if let expectedDigest = package.sha256 {
                guard try PackageDigest.sha256Hex(fileURL: download.fileURL)
                    .caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                    throw PackageRepositoryError.checksumMismatch
                }
            }
            return download.fileURL
        } catch {
            try? FileManager.default.removeItem(at: download.fileURL)
            throw error
        }
    }

    private static func downloadFile(
        from rawURL: URL,
        maximumBytes: Int?
    ) async throws -> (fileURL: URL, finalURL: URL) {
        let url = try PackageRepositoryURLPolicy.validate(rawURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = PackageRepositoryRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("3105", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let finalURL = response.url,
              (try? PackageRepositoryURLPolicy.validate(finalURL)) != nil else {
            throw PackageRepositoryError.sourceUnavailable
        }
        if let maximumBytes {
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard let byteCount = values.fileSize, byteCount <= maximumBytes else {
                throw PackageRepositoryError.invalidManifest
            }
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(rawURL.pathExtension)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return (destination, finalURL)
        } catch {
            throw PackageRepositoryError.sourceUnavailable
        }
    }
}
