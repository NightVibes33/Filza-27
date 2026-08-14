import Foundation

struct PatchProjectDraft: Equatable {
    let name: String
    let rules: [PatchRule]
}

struct PatchDraftCandidate: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let byteCount: Int64

    var id: String { relativePath }
}

enum PatchDraftService {
    static func candidate(
        for fileURL: URL,
        containerRoot: URL,
        fileManager: FileManager = .default
    ) throws -> PatchDraftCandidate {
        let root = PatchPathValidator.canonicalFileURL(containerRoot)
        let file = PatchPathValidator.canonicalFileURL(fileURL)
        let relativePath = try containedRelativePath(for: file, containerRoot: root)
        try rejectSymbolicLinks(
            relativePath: relativePath,
            containerRoot: root,
            fileManager: fileManager
        )

        guard fileManager.fileExists(atPath: file.path) else {
            throw PatchPackageError.invalidProject
        }
        let values = try file.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isSymbolicLink != true else {
            throw PatchPackageError.symbolicLinkUnsupported
        }
        guard values.isDirectory != true, values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        let byteCount = Int64(values.fileSize ?? 0)
        return PatchDraftCandidate(
            url: file,
            relativePath: relativePath,
            byteCount: byteCount
        )
    }

    static func candidates(
        in folderURL: URL,
        containerRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [PatchDraftCandidate] {
        let root = PatchPathValidator.canonicalFileURL(containerRoot)
        let folder = PatchPathValidator.canonicalFileURL(folderURL)
        let folderRelativePath = try containedRelativePath(for: folder, containerRoot: root)
        try rejectSymbolicLinks(
            relativePath: folderRelativePath,
            containerRoot: root,
            fileManager: fileManager
        )

        let folderValues = try folder.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard folderValues.isSymbolicLink != true else {
            throw PatchPackageError.symbolicLinkUnsupported
        }
        guard folderValues.isDirectory == true else {
            throw PatchPackageError.invalidProject
        }
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw PatchPackageError.invalidProject
        }

        var result: [PatchDraftCandidate] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            result.append(try candidate(for: item, containerRoot: root, fileManager: fileManager))
        }
        guard !enumerationFailed else { throw PatchPackageError.invalidProject }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    static func makeDraft(
        bundleID: String,
        containerRoot: URL,
        candidates: [PatchDraftCandidate],
        suggestedName: String,
        fileManager: FileManager = .default
    ) throws -> PatchProjectDraft {
        let canonicalBundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        guard !candidates.isEmpty,
              candidates.count <= PatchPackageLimits.maximumRuleCount else {
            throw candidates.count > PatchPackageLimits.maximumRuleCount
                ? PatchPackageError.sizeLimitExceeded
                : PatchPackageError.invalidProject
        }

        var rules: [PatchRule] = []
        var seenPaths = Set<String>()
        for suppliedCandidate in candidates {
            let verifiedCandidate = try candidate(
                for: suppliedCandidate.url,
                containerRoot: containerRoot,
                fileManager: fileManager
            )
            guard seenPaths.insert(verifiedCandidate.relativePath).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            rules.append(PatchRule(
                bundleID: canonicalBundleID,
                relativePath: verifiedCandidate.relativePath,
                replacementFilename: "",
                replacementData: Data()
            ))
        }

        return PatchProjectDraft(
            name: suggestedName.trimmingCharacters(in: .whitespacesAndNewlines),
            rules: rules
        )
    }

    private static func containedRelativePath(for item: URL, containerRoot: URL) throws -> String {
        let rootPath = containerRoot.path
        let itemPath = item.path
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
        return try PatchPathValidator.canonicalRelativePath(relativePath)
    }

    private static func rejectSymbolicLinks(
        relativePath: String,
        containerRoot: URL,
        fileManager: FileManager
    ) throws {
        var cursor = containerRoot
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            guard fileManager.fileExists(atPath: cursor.path) else {
                throw PatchPackageError.invalidProject
            }
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
        }
    }
}
