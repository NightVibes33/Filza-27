import Foundation

struct PatchRule: Codable, Identifiable, Hashable {
    var id: UUID
    var bundleID: String
    var relativePath: String
    var replacementFilename: String
    var replacementData: Data

    init(
        id: UUID = UUID(),
        bundleID: String,
        relativePath: String,
        replacementFilename: String,
        replacementData: Data
    ) {
        self.id = id
        self.bundleID = bundleID
        self.relativePath = relativePath
        self.replacementFilename = replacementFilename
        self.replacementData = replacementData
    }

    /// A zero-byte file is a valid replacement; the filename records that the
    /// user explicitly supplied a payload for this path-only draft rule.
    var hasReplacement: Bool {
        !replacementFilename.isEmpty
    }
}

struct PatchProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var rules: [PatchRule]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        rules: [PatchRule]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rules = rules
    }
}

struct PatchPackageSummary: Equatable, Identifiable {
    var id: UUID { packageID }
    let packageID: UUID
    let isPasswordProtected: Bool
    let keyFingerprint: Data
}

struct EncodedPatchPackage {
    let data: Data
    let contentKey: Data
}

struct DecodedPatchPackage {
    let project: PatchProject
    let contentKey: Data
}

enum PatchPackageError: Error, Equatable {
    case unsupportedFormat
    case unsupportedVersion
    case invalidPasswordOrCorruptedPackage
    case invalidBundleIdentifier
    case unsafeTargetPath
    case sizeLimitExceeded
    case duplicateTarget
    case invalidProject
    case keychainFailed
    case targetAppUnavailable(String)
    case symbolicLinkUnsupported
    case applyFailed
    case restoreFailed
}

extension PatchPackageError: LocalizedError {
    var localizationKey: String {
        switch self {
        case .unsupportedFormat: return "patch.error.unsupported_format"
        case .unsupportedVersion: return "patch.error.unsupported_version"
        case .invalidPasswordOrCorruptedPackage: return "patch.error.password_or_corrupt"
        case .invalidBundleIdentifier: return "patch.error.invalid_bundle"
        case .unsafeTargetPath: return "patch.error.unsafe_path"
        case .sizeLimitExceeded: return "patch.error.size_limit"
        case .duplicateTarget: return "patch.error.duplicate_target"
        case .invalidProject: return "patch.error.invalid_project"
        case .keychainFailed: return "patch.error.keychain"
        case .targetAppUnavailable: return "patch.error.app_unavailable"
        case .symbolicLinkUnsupported: return "patch.error.symlink"
        case .applyFailed: return "patch.error.apply"
        case .restoreFailed: return "patch.error.restore"
        }
    }

    var errorDescription: String? {
        let message = String(localized: String.LocalizationValue(localizationKey))
        if let localizationArgument {
            return String(format: message, localizationArgument)
        }
        return message
    }

    var localizationArgument: String? {
        if case .targetAppUnavailable(let bundleID) = self {
            return bundleID
        }
        return nil
    }
}

enum PatchPackageLimits {
    static let maximumRuleCount = 64
    static let maximumReplacementBytes = 64 * 1_024 * 1_024
    static let maximumTotalReplacementBytes = 256 * 1_024 * 1_024
    static let maximumPackageBytes = 260 * 1_024 * 1_024
    static let maximumPathBytes = 4_096
    static let maximumPasswordBytes = 1_024
    static let minimumKDFIterations = 100_000
    static let defaultKDFIterations = 250_000
    static let maximumKDFIterations = 1_000_000
}

enum PatchPathValidator {
    private static let applicationRoot = "/private/var/mobile/Containers/Data/Application"

    static func canonicalBundleIdentifier(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 255,
              UUID(uuidString: value) == nil,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PatchPackageError.invalidBundleIdentifier
        }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            throw PatchPackageError.invalidBundleIdentifier
        }

        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ scalar in
                      let value = scalar.value
                      return (48...57).contains(value)
                          || (65...90).contains(value)
                          || (97...122).contains(value)
                          || value == 45
                  }),
                  component.first != "-",
                  component.last != "-"
            else {
                throw PatchPackageError.invalidBundleIdentifier
            }
        }
        return value
    }

    static func canonicalRelativePath(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= PatchPackageLimits.maximumPathBytes,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("//"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PatchPackageError.unsafeTargetPath
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PatchPackageError.unsafeTargetPath
        }
        return components.joined(separator: "/")
    }

    static func resolveTargetURL(
        bundleID: String,
        relativePath: String,
        containerRoot: URL
    ) throws -> URL {
        _ = try canonicalBundleIdentifier(bundleID)
        let path = try canonicalRelativePath(relativePath)
        let root = canonicalFileURL(containerRoot)

        guard root.deletingLastPathComponent().path == applicationRoot,
              UUID(uuidString: root.lastPathComponent) != nil
        else {
            throw PatchPackageError.unsafeTargetPath
        }

        return try resolveContainedTargetURL(relativePath: path, containerRoot: root)
    }

    static func resolveContainedTargetURL(relativePath: String, containerRoot: URL) throws -> URL {
        let path = try canonicalRelativePath(relativePath)
        let root = canonicalFileURL(containerRoot)
        let target = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        return target
    }

    static func canonicalFileURL(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }
}
