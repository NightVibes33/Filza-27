import Foundation

struct PatchProjectDraft: Equatable {
    let name: String
    let bundleIdentifiers: [String]
    let directories: [PatchDirectory]
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
        directories: [String] = [],
        fileManager: FileManager = .default
    ) throws -> PatchProjectDraft {
        let canonicalBundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        guard !candidates.isEmpty || !directories.isEmpty else {
            throw PatchPackageError.invalidProject
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
            let replacementData = try Data(contentsOf: verifiedCandidate.url, options: .mappedIfSafe)
            rules.append(PatchRule(
                bundleID: canonicalBundleID,
                relativePath: verifiedCandidate.relativePath,
                replacementFilename: verifiedCandidate.url.lastPathComponent,
                replacementData: replacementData
            ))
        }

        var seenDirectories = Set<String>()
        let patchDirectories = try directories.map { suppliedPath -> PatchDirectory in
            let relativePath = try PatchPathValidator.canonicalRelativePath(suppliedPath)
            guard seenDirectories.insert(relativePath).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            return PatchDirectory(bundleID: canonicalBundleID, relativePath: relativePath)
        }

        return PatchProjectDraft(
            name: suggestedName.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleIdentifiers: [canonicalBundleID],
            directories: patchDirectories,
            rules: rules
        )
    }

    static func makeDraft(
        bundleID: String,
        containerRoot: URL,
        itemURL: URL,
        suggestedName: String,
        fileManager: FileManager = .default
    ) throws -> PatchProjectDraft {
        let values = try itemURL.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw PatchPackageError.symbolicLinkUnsupported
        }
        if values.isDirectory == true {
            let folderCandidates = try candidates(
                in: itemURL,
                containerRoot: containerRoot,
                fileManager: fileManager
            )
            let directoryPaths = try directoryRelativePaths(
                in: itemURL,
                containerRoot: containerRoot,
                fileManager: fileManager
            )
            return try makeDraft(
                bundleID: bundleID,
                containerRoot: containerRoot,
                candidates: folderCandidates,
                suggestedName: suggestedName,
                directories: directoryPaths,
                fileManager: fileManager
            )
        }
        guard values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        return try makeDraft(
            bundleID: bundleID,
            containerRoot: containerRoot,
            candidates: [try candidate(
                for: itemURL,
                containerRoot: containerRoot,
                fileManager: fileManager
            )],
            suggestedName: suggestedName,
            fileManager: fileManager
        )
    }

    private static func directoryRelativePaths(
        in folderURL: URL,
        containerRoot: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let root = PatchPathValidator.canonicalFileURL(containerRoot)
        let folder = PatchPathValidator.canonicalFileURL(folderURL)
        var result = [try containedRelativePath(for: folder, containerRoot: root)]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw PatchPackageError.invalidProject
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw PatchPackageError.symbolicLinkUnsupported
            }
            if values.isDirectory == true {
                result.append(try containedRelativePath(for: item, containerRoot: root))
            }
        }
        guard !enumerationFailed else { throw PatchPackageError.invalidProject }
        return result.sorted()
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
