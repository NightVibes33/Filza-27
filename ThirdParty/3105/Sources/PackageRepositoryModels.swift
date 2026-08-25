import CryptoKit
import Foundation

enum PackageRepositoryError: Error, Equatable {
    case insecureURL
    case unsupportedSchema
    case invalidManifest
    case invalidPackage
    case duplicatePackage
    case sourceAlreadyExists
    case sourceUnavailable
    case checksumMismatch
    case packageIdentityMismatch
    case incompatiblePackage
    case importUnavailable
}

extension PackageRepositoryError: LocalizedError {
    var localizationKey: String {
        switch self {
        case .insecureURL: return "repository.error.insecure_url"
        case .unsupportedSchema: return "repository.error.unsupported_schema"
        case .invalidManifest: return "repository.error.invalid_manifest"
        case .invalidPackage: return "repository.error.invalid_package"
        case .duplicatePackage: return "repository.error.duplicate_package"
        case .sourceAlreadyExists: return "repository.error.source_exists"
        case .sourceUnavailable: return "repository.error.source_unavailable"
        case .checksumMismatch: return "repository.error.checksum"
        case .packageIdentityMismatch: return "repository.error.identity"
        case .incompatiblePackage: return "repository.error.incompatible"
        case .importUnavailable: return "repository.error.import_unavailable"
        }
    }

    var errorDescription: String? {
        String(localized: String.LocalizationValue(localizationKey))
    }
}

struct PackageRepositoryDocument: Decodable {
    let schemaVersion: Int
    let identifier: String
    let name: String
    let description: String?
    let icon: String?
    let packages: [PackageRepositoryPackageDocument]
}

struct PackageRepositoryCatalogDocument: Decodable {
    let schemaVersion: Int
    let sources: [String]
}

struct PackageRepositoryPackageDocument: Decodable {
    let identifier: String
    let kind: RepositoryPackageKind?
    let name: String
    let author: String
    let version: String
    let summary: String
    let description: String?
    let category: String?
    let tags: [String]?
    let publishedAt: String?
    let icon: String?
    let banner: String?
    let screenshots: [String]?
    let download: String
    let sha256: String?
    let size: UInt64?
    let supportedOS: [PackageOSRange]
    let changelog: String?
    let featured: Bool?
    let isPrivate: Bool?
    let password: String?
}

enum RepositoryPackageKind: String, Codable, Hashable {
    case patch
    case wallpaper
}

struct PackageOSRange: Codable, Hashable {
    let minimum: String
    let maximum: String
    let builds: [String]?
}

struct PackageRepository: Identifiable, Hashable {
    let identifier: String
    let name: String
    let summary: String?
    let iconURL: URL?
    let sourceURL: URL
    let packages: [RepositoryPackage]

    var id: String { identifier }
}

struct RepositoryPackage: Identifiable, Hashable {
    let identifier: String
    let kind: RepositoryPackageKind
    let name: String
    let author: String
    let version: String
    let summary: String
    let details: String?
    let category: String?
    let tags: [String]
    let publishedAt: Date?
    let iconURL: URL?
    let bannerURL: URL?
    let screenshotURLs: [URL]
    let downloadURL: URL
    let sha256: String?
    let expectedSize: UInt64?
    let supportedOS: [PackageOSRange]
    let changelog: String?
    let isFeatured: Bool
    let isPrivate: Bool
    let sharedPassword: String?

    var id: String { identifier }
}

struct RepositoryPackageRecord: Identifiable, Hashable {
    let sourceID: UUID
    let sourceName: String
    let sourceURL: URL
    let package: RepositoryPackage

    var id: String {
        sourceID.uuidString + ":" + package.identifier
    }

    var repositoryIdentity: String {
        sourceURL.absoluteString + "#" + package.identifier
    }
}

struct RepositoryPackageResolutionIndex: Codable, Equatable {
    private var packageIDsByKey: [String: UUID] = [:]

    mutating func record(
        _ packageID: UUID,
        sourceURL: URL,
        packageIdentifier: String
    ) {
        packageIDsByKey[Self.key(
            sourceURL: sourceURL,
            packageIdentifier: packageIdentifier
        )] = packageID
    }

    func packageID(
        sourceURL: URL,
        packageIdentifier: String
    ) -> UUID? {
        packageIDsByKey[Self.key(
            sourceURL: sourceURL,
            packageIdentifier: packageIdentifier
        )]
    }

    private static func key(
        sourceURL: URL,
        packageIdentifier: String
    ) -> String {
        sourceURL.absoluteString + "\n" + packageIdentifier
    }
}

struct RepositorySource: Codable, Identifiable, Hashable {
    let id: UUID
    var manifestURL: URL
    var isEnabled: Bool
    let addedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case manifestURL
        case isEnabled
        case addedAt
    }

    init(
        id: UUID = UUID(),
        manifestURL: URL,
        isEnabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.manifestURL = manifestURL
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        manifestURL = try container.decode(URL.self, forKey: .manifestURL)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        // Sources are always active now. Decode the legacy flag only for
        // backwards compatibility, then intentionally discard its value.
        _ = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        isEnabled = true
    }
}

enum RepositorySourceState: Equatable {
    case idle
    case loading
    case loaded(Date)
    case failed(PackageRepositoryError)
}

enum PackageCompatibility: Equatable {
    case compatible
    case incompatible
    case unknown
}

enum PackageRepositoryLimits {
    static let maximumManifestBytes = 5 * 1_024 * 1_024
    static let maximumCatalogBytes = 256 * 1_024
    static let maximumCatalogSourceCount = 250
    static let maximumPackageCount = 5_000
    static let maximumIdentifierBytes = 128
    static let maximumNameBytes = 160
    static let maximumSummaryBytes = 500
    static let maximumDescriptionBytes = 8_192
    static let maximumChangelogBytes = 32_768
    static let maximumTagCount = 24
    static let maximumTagBytes = 80
    static let maximumScreenshotCount = 12
}

enum PackageRepositoryDefaults {
    static let catalogURL = URL(
        string: "https://raw.githubusercontent.com/YangJiiii/3105-repo/main/sources.json"
    )!
}

enum PackageRepositoryURLPolicy {
    static func validate(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              url.fragment == nil,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !isIPLiteral(host)
        else {
            throw PackageRepositoryError.insecureURL
        }
        return url.absoluteURL
    }

    static func resolve(_ rawValue: String, relativeTo baseURL: URL) throws -> URL {
        guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else {
            throw PackageRepositoryError.insecureURL
        }
        return try validate(resolved)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let value = Int(component),
                  (0...255).contains(value) else {
                return false
            }
            return true
        }
    }
}

enum PackageRepositoryValidator {
    static func decode(_ data: Data, sourceURL: URL) throws -> PackageRepository {
        guard data.count <= PackageRepositoryLimits.maximumManifestBytes else {
            throw PackageRepositoryError.invalidManifest
        }
        let trustedSourceURL = try PackageRepositoryURLPolicy.validate(sourceURL)
        let document: PackageRepositoryDocument
        do {
            document = try JSONDecoder().decode(PackageRepositoryDocument.self, from: data)
        } catch {
            throw PackageRepositoryError.invalidManifest
        }

        guard document.schemaVersion == 1 else {
            throw PackageRepositoryError.unsupportedSchema
        }
        guard isValidIdentifier(document.identifier),
              isValidText(document.name, maximumBytes: PackageRepositoryLimits.maximumNameBytes),
              isValidOptionalText(
                document.description,
                maximumBytes: PackageRepositoryLimits.maximumDescriptionBytes,
                allowsLineBreaks: true
              ),
              document.packages.count <= PackageRepositoryLimits.maximumPackageCount else {
            throw PackageRepositoryError.invalidManifest
        }

        let iconURL = try document.icon.map {
            try PackageRepositoryURLPolicy.resolve($0, relativeTo: trustedSourceURL)
        }
        var identifiers = Set<String>()
        var packages: [RepositoryPackage] = []
        packages.reserveCapacity(document.packages.count)

        for rawPackage in document.packages {
            guard identifiers.insert(rawPackage.identifier).inserted else {
                throw PackageRepositoryError.duplicatePackage
            }
            packages.append(
                try validate(rawPackage, sourceURL: trustedSourceURL)
            )
        }

        return PackageRepository(
            identifier: document.identifier,
            name: document.name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: trimmedOptional(document.description),
            iconURL: iconURL,
            sourceURL: trustedSourceURL,
            packages: packages
        )
    }

    private static func validate(
        _ package: PackageRepositoryPackageDocument,
        sourceURL: URL
    ) throws -> RepositoryPackage {
        guard isValidIdentifier(package.identifier),
              isValidText(package.name, maximumBytes: PackageRepositoryLimits.maximumNameBytes),
              isValidText(package.author, maximumBytes: PatchPackageLimits.maximumAuthorBytes),
              isValidText(package.version, maximumBytes: 64),
              isValidText(package.summary, maximumBytes: PackageRepositoryLimits.maximumSummaryBytes),
              isValidOptionalText(
                package.description,
                maximumBytes: PackageRepositoryLimits.maximumDescriptionBytes,
                allowsLineBreaks: true
              ),
              isValidOptionalText(package.category, maximumBytes: 80),
              isValidOptionalText(
                package.changelog,
                maximumBytes: PackageRepositoryLimits.maximumChangelogBytes,
                allowsLineBreaks: true
              ),
              isValidOptionalText(package.publishedAt, maximumBytes: 64),
              isValidOptionalPassword(package.password),
              (package.tags?.count ?? 0) <= PackageRepositoryLimits.maximumTagCount,
              (package.screenshots?.count ?? 0)
                <= PackageRepositoryLimits.maximumScreenshotCount,
              package.expectedSizeIsValid else {
            throw PackageRepositoryError.invalidPackage
        }

        let canonicalTags = try canonicalTags(
            category: package.category,
            tags: package.tags ?? []
        )
        let publishedAt: Date?
        if let rawPublishedAt = package.publishedAt {
            guard let parsedDate = PackagePublicationDate.parse(rawPublishedAt) else {
                throw PackageRepositoryError.invalidPackage
            }
            publishedAt = parsedDate
        } else {
            publishedAt = nil
        }

        for range in package.supportedOS {
            guard let minimum = PackageSystemVersion(range.minimum),
                  let maximum = PackageSystemVersion(range.maximum),
                  minimum <= maximum,
                  (range.builds ?? []).allSatisfy({
                      isValidText($0, maximumBytes: 64)
                  }) else {
                throw PackageRepositoryError.invalidPackage
            }
        }

        let iconURL = try package.icon.map {
            try PackageRepositoryURLPolicy.resolve($0, relativeTo: sourceURL)
        }
        let bannerURL = try package.banner.map {
            try PackageRepositoryURLPolicy.resolve($0, relativeTo: sourceURL)
        }
        let screenshotURLs = try (package.screenshots ?? []).map {
            try PackageRepositoryURLPolicy.resolve($0, relativeTo: sourceURL)
        }
        let downloadURL = try PackageRepositoryURLPolicy.resolve(
            package.download,
            relativeTo: sourceURL
        )
        let kind = package.kind ?? .patch
        guard packageIntegrityIsValid(
            kind: kind,
            sha256: package.sha256,
            downloadURL: downloadURL
        ) else {
            throw PackageRepositoryError.invalidPackage
        }
        if kind == .wallpaper,
           (downloadURL.pathExtension.lowercased() != "tendies"
                || package.password != nil) {
                throw PackageRepositoryError.invalidPackage
        }

        return RepositoryPackage(
            identifier: package.identifier,
            kind: kind,
            name: package.name.trimmingCharacters(in: .whitespacesAndNewlines),
            author: package.author.trimmingCharacters(in: .whitespacesAndNewlines),
            version: package.version.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: package.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            details: trimmedOptional(package.description),
            category: trimmedOptional(package.category),
            tags: canonicalTags,
            publishedAt: publishedAt,
            iconURL: iconURL,
            bannerURL: bannerURL,
            screenshotURLs: screenshotURLs,
            downloadURL: downloadURL,
            sha256: package.sha256?.lowercased(),
            expectedSize: package.size,
            supportedOS: package.supportedOS,
            changelog: trimmedOptional(package.changelog),
            isFeatured: package.featured ?? false,
            isPrivate: package.isPrivate ?? false,
            sharedPassword: package.password
        )
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= PackageRepositoryLimits.maximumIdentifierBytes,
              trimmed.first != "-",
              trimmed.last != "-" else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45
                || value == 46
                || value == 95
        }
    }

    private static func isValidDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...70).contains(value)
                || (97...102).contains(value)
        }
    }

    private static func packageIntegrityIsValid(
        kind: RepositoryPackageKind,
        sha256: String?,
        downloadURL: URL
    ) -> Bool {
        if let sha256 {
            return isValidDigest(sha256)
        }
        return kind == .wallpaper
            && PackageRepositoryPinnedWallpaperURLPolicy.validate(downloadURL)
    }

    private static func isValidText(
        _ value: String,
        maximumBytes: Int,
        allowsLineBreaks: Bool = false
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= maximumBytes
            && !trimmed.unicodeScalars.contains { scalar in
                guard CharacterSet.controlCharacters.contains(scalar) else {
                    return false
                }
                return !allowsLineBreaks
                    || (scalar.value != 10 && scalar.value != 13)
            }
    }

    private static func isValidOptionalText(
        _ value: String?,
        maximumBytes: Int,
        allowsLineBreaks: Bool = false
    ) -> Bool {
        guard let value else { return true }
        return isValidText(
            value,
            maximumBytes: maximumBytes,
            allowsLineBreaks: allowsLineBreaks
        )
    }

    private static func isValidOptionalPassword(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= PatchPackageLimits.maximumPasswordBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalTags(
        category: String?,
        tags: [String]
    ) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let candidates = (category.map { [$0] } ?? []) + tags

        for candidate in candidates {
            guard isValidText(
                candidate,
                maximumBytes: PackageRepositoryLimits.maximumTagBytes
            ) else {
                throw PackageRepositoryError.invalidPackage
            }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

enum PackageRepositoryPinnedWallpaperURLPolicy {
    static func validate(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.query == nil,
              url.fragment == nil,
              url.pathExtension.lowercased() == "tendies" else {
            return false
        }
        let components = url.pathComponents
        guard components.count >= 6,
              components[1] == "SerStars",
              components[2] == "Nugget-Wallpapers" else {
            return false
        }
        let revision = components[3]
        return revision.utf8.count == 40
            && revision.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (48...57).contains(value)
                    || (65...70).contains(value)
                    || (97...102).contains(value)
            }
    }
}

enum PackageRepositoryCatalogValidator {
    static func decode(_ data: Data, catalogURL: URL) throws -> [URL] {
        guard data.count <= PackageRepositoryLimits.maximumCatalogBytes else {
            throw PackageRepositoryError.invalidManifest
        }
        let trustedCatalogURL = try PackageRepositoryURLPolicy.validate(catalogURL)
        let document: PackageRepositoryCatalogDocument
        do {
            document = try JSONDecoder().decode(
                PackageRepositoryCatalogDocument.self,
                from: data
            )
        } catch {
            throw PackageRepositoryError.invalidManifest
        }
        guard document.schemaVersion == 1 else {
            throw PackageRepositoryError.unsupportedSchema
        }
        guard document.sources.count
                <= PackageRepositoryLimits.maximumCatalogSourceCount else {
            throw PackageRepositoryError.invalidManifest
        }

        var seen = Set<String>()
        var result: [URL] = []
        result.reserveCapacity(document.sources.count)

        for rawSource in document.sources {
            let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= 2_048,
                  !trimmed.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                  ) else {
                throw PackageRepositoryError.invalidManifest
            }
            let url = try PackageRepositoryURLPolicy.resolve(
                trimmed,
                relativeTo: trustedCatalogURL
            )
            let key = url.absoluteString.lowercased()
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}

enum RepositorySourceMergePolicy {
    static func merge(
        existing: [RepositorySource],
        catalogURLs: [URL]
    ) -> [RepositorySource] {
        var result = existing
        var seen = Set(existing.map {
            $0.manifestURL.absoluteString.lowercased()
        })
        for url in catalogURLs
        where seen.insert(url.absoluteString.lowercased()).inserted {
            result.append(RepositorySource(manifestURL: url))
        }
        return result
    }
}

private extension PackageRepositoryPackageDocument {
    var expectedSizeIsValid: Bool {
        size.map { $0 > 0 } ?? true
    }
}

private struct PackageSystemVersion: Comparable, Hashable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy(\.isNumber)
              }) else {
            return nil
        }
        let values = components.compactMap { Int($0) }
        guard values.count == components.count else { return nil }
        major = values[0]
        minor = values.count > 1 ? values[1] : 0
        patch = values.count > 2 ? values[2] : 0
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: PackageSystemVersion, rhs: PackageSystemVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum PackageCompatibilityEvaluator {
    static func evaluate(
        _ ranges: [PackageOSRange],
        major: Int,
        minor: Int,
        patch: Int,
        build: String
    ) -> PackageCompatibility {
        guard !ranges.isEmpty else { return .unknown }
        let current = PackageSystemVersion(major: major, minor: minor, patch: patch)
        for range in ranges {
            guard let minimum = PackageSystemVersion(range.minimum),
                  let maximum = PackageSystemVersion(range.maximum),
                  (minimum...maximum).contains(current) else {
                continue
            }
            if let builds = range.builds, !builds.isEmpty {
                return builds.contains(build) ? .compatible : .incompatible
            }
            return .compatible
        }
        return .incompatible
    }
}

struct RepositoryTagGroup: Identifiable, Hashable {
    let name: String
    let packages: [RepositoryPackage]

    var id: String {
        name
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}

enum PackageRepositoryTagIndex {
    static func groups(for packages: [RepositoryPackage]) -> [RepositoryTagGroup] {
        var names: [String: String] = [:]
        var packagesByTag: [String: [RepositoryPackage]] = [:]

        for package in packages {
            for tag in package.tags {
                let key = tag
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    .lowercased()
                names[key] = names[key] ?? tag
                packagesByTag[key, default: []].append(package)
            }
        }

        return packagesByTag.compactMap { key, taggedPackages in
            guard let name = names[key] else { return nil }
            return RepositoryTagGroup(name: name, packages: taggedPackages)
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

enum PackageRepositoryNewIndex {
    static func sorted(_ packages: [RepositoryPackage]) -> [RepositoryPackage] {
        sorted(
            packages,
            publishedAt: \.publishedAt,
            name: \.name
        )
    }

    static func sorted(
        _ records: [RepositoryPackageRecord]
    ) -> [RepositoryPackageRecord] {
        sorted(
            records,
            publishedAt: \.package.publishedAt,
            name: \.package.name
        )
    }

    private static func sorted<Value>(
        _ values: [Value],
        publishedAt: KeyPath<Value, Date?>,
        name: KeyPath<Value, String>
    ) -> [Value] {
        values.sorted { lhs, rhs in
            let lhsDate = lhs[keyPath: publishedAt]
            let rhsDate = rhs[keyPath: publishedAt]
            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs[keyPath: name].localizedCaseInsensitiveCompare(
                    rhs[keyPath: name]
                ) == .orderedAscending
            }
        }
    }
}

enum PackageRepositoryFeedPolicy {
    static let maximumVisiblePackages = 10

    static func home(
        _ records: [RepositoryPackageRecord]
    ) -> [RepositoryPackageRecord] {
        Array(records.shuffled().prefix(maximumVisiblePackages))
    }

    static func newest(
        _ records: [RepositoryPackageRecord]
    ) -> [RepositoryPackageRecord] {
        Array(
            PackageRepositoryNewIndex.sorted(records)
                .prefix(maximumVisiblePackages)
        )
    }
}

private enum PackagePublicationDate {
    static func parse(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum PackageDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576),
                  !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
