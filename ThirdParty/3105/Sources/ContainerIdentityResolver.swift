import Foundation

struct ContainerMetadata: Equatable {
    let bundleID: String
    let displayName: String
}

enum ContainerResolution: Equatable {
    case resolved(ContainerMetadata)
    case accessFailed(Int64)
    case metadataUnavailable
    case unsupportedIdentifier(String)

    var logDescription: String {
        switch self {
        case .resolved(let metadata):
            return "resolved \(metadata.bundleID)"
        case .accessFailed(let code):
            return "access failed (\(code))"
        case .metadataUnavailable:
            return "metadata unavailable"
        case .unsupportedIdentifier(let identifier):
            return "identifier '\(identifier)' skipped"
        }
    }
}

enum ContainerIdentityResolver {
    static func fallbackIdentity(containerPath: String) -> ContainerMetadata {
        let identifier = (containerPath as NSString).lastPathComponent
        let shortIdentifier = String(identifier.prefix(8))
        return ContainerMetadata(
            bundleID: identifier,
            displayName: "Container \(shortIdentifier)"
        )
    }

    static func resolve(
        containerPath: String,
        grantAccess: (String) -> Int64,
        releaseAccess: (Int64) -> Void,
        loadMetadata: (String) -> ContainerMetadata?
    ) -> ContainerResolution {
        let handle = grantAccess(containerPath)
        guard handle >= 0 else { return .accessFailed(handle) }
        defer { releaseAccess(handle) }

        guard let metadata = loadMetadata(containerPath) else {
            return .metadataUnavailable
        }

        let bundleID = metadata.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return .metadataUnavailable }
        guard !bundleID.hasPrefix("systemgroup.") else {
            return .unsupportedIdentifier(bundleID)
        }

        return .resolved(ContainerMetadata(bundleID: bundleID, displayName: metadata.displayName))
    }
}
