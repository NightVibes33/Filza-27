import Foundation
import Darwin

enum FileManagerOperationError: Error, Equatable, LocalizedError {
    case invalidName
    case nameTooLong
    case itemAlreadyExists
    case sourceMissing
    case destinationMissing
    case sourceIsDirectory
    case destinationIsDirectory
    case destinationNotDirectory
    case symbolicLinkUnsupported
    case recursiveDestination
    case sourceTooLarge
    case cannotCreate
    case cannotRename
    case cannotDelete
    case cannotImport
    case cannotCopy
    case cannotMove
    case cannotArchive
    case cannotExtract
    case unsafeArchive
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a valid file or folder name."
        case .nameTooLong: return "The name is too long."
        case .itemAlreadyExists: return "An item with this name already exists."
        case .sourceMissing: return "The selected source file is unavailable."
        case .destinationMissing: return "The destination no longer exists."
        case .sourceIsDirectory: return "Select a file, not a folder."
        case .destinationIsDirectory: return "A folder with this name already exists."
        case .destinationNotDirectory: return "The destination is not a folder."
        case .symbolicLinkUnsupported: return "Symbolic links are not supported."
        case .recursiveDestination: return "A folder cannot be copied or moved into itself."
        case .sourceTooLarge: return "The selected file is too large."
        case .cannotCreate: return "The item could not be created."
        case .cannotRename: return "The item could not be renamed."
        case .cannotDelete: return "The item could not be deleted."
        case .cannotImport: return "The file could not be imported safely."
        case .cannotCopy: return "The selected items could not be copied."
        case .cannotMove: return "The selected items could not be moved."
        case .cannotArchive: return "The ZIP archive could not be created."
        case .cannotExtract: return "The ZIP archive could not be extracted."
        case .unsafeArchive: return "The ZIP archive contains unsafe or unsupported entries."
        case .insufficientSpace: return "There is not enough free space to extract this archive."
        }
    }
}

enum FileTransferMode: Equatable {
    case copy
    case move
}

enum FileConflictPolicy: Equatable {
    case fail
    case replace
    case keepBoth
}

enum FileTransferDisposition: Equatable {
    case copied
    case moved
    case replaced
    case renamed
}

struct FileTransferResult: Equatable {
    let sourceURL: URL
    let destinationURL: URL
    let disposition: FileTransferDisposition
}

struct FileArchiveResult: Equatable {
    let archiveURL: URL
    let entryCount: Int
    let sourceBytes: Int64
}

enum FileImportDisposition: Equatable {
    case imported
    case replaced
}

struct FileImportResult: Equatable {
    let destinationURL: URL
    let byteCount: Int64
    let disposition: FileImportDisposition
}

struct FileImportSession: Equatable {
    let destinationDirectory: URL
    private(set) var pendingSourceURLs: [URL]
    private(set) var replaceAll = false
    private(set) var importedCount = 0
    private(set) var replacedCount = 0
    private(set) var failedCount = 0
    private(set) var isCancelled = false

    init(destinationDirectory: URL, sourceURLs: [URL]) {
        self.destinationDirectory = destinationDirectory
        self.pendingSourceURLs = sourceURLs
    }

    var isComplete: Bool { pendingSourceURLs.isEmpty }

    mutating func takeNext() -> URL? {
        guard !pendingSourceURLs.isEmpty else { return nil }
        return pendingSourceURLs.removeFirst()
    }

    mutating func enableReplaceAll() {
        replaceAll = true
    }

    mutating func record(_ disposition: FileImportDisposition) {
        switch disposition {
        case .imported: importedCount += 1
        case .replaced: replacedCount += 1
        }
    }

    mutating func recordFailure() {
        failedCount += 1
    }

    mutating func cancel() {
        pendingSourceURLs.removeAll()
        isCancelled = true
    }
}

enum FileManagerService {
    private static let maximumNameByteCount = 255
    private static let copyChunkSize = 1_024 * 1_024

    static func validatedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FileManagerOperationError.invalidName
        }
        guard name.lengthOfBytes(using: .utf8) <= maximumNameByteCount else {
            throw FileManagerOperationError.nameTooLong
        }
        return name
    }

    static func destinationURL(
        named rawName: String,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try validateDirectory(directoryURL, fileManager: fileManager)
        let name = try validatedName(rawName)
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    static func createFile(
        named rawName: String,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destinationURL = try destinationURL(
            named: rawName,
            in: directoryURL,
            fileManager: fileManager
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileManagerOperationError.itemAlreadyExists
        }
        try createExclusiveFile(
            at: destinationURL,
            existingError: .itemAlreadyExists,
            failureError: .cannotCreate
        )
        return destinationURL
    }

    static func createFolder(
        named rawName: String,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destinationURL = try destinationURL(
            named: rawName,
            in: directoryURL,
            fileManager: fileManager
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileManagerOperationError.itemAlreadyExists
        }
        do {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: false
            )
            return destinationURL
        } catch {
            throw FileManagerOperationError.cannotCreate
        }
    }

    static func renameItem(
        at sourceURL: URL,
        to rawName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let sourceValues = try values(
            for: sourceURL,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard sourceValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        let destinationURL = try destinationURL(
            named: rawName,
            in: sourceURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return sourceURL
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileManagerOperationError.itemAlreadyExists
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw FileManagerOperationError.cannotRename
        }
    }

    static func deleteItem(
        at itemURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let itemValues = try values(
            for: itemURL,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard itemValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        do {
            try fileManager.removeItem(at: itemURL)
        } catch {
            throw FileManagerOperationError.cannotDelete
        }
    }

    static func transferItem(
        at sourceURL: URL,
        into directoryURL: URL,
        mode: FileTransferMode,
        conflictPolicy: FileConflictPolicy,
        fileManager: FileManager = .default
    ) throws -> FileTransferResult {
        let source = sourceURL.standardizedFileURL
        let destinationDirectory = directoryURL.standardizedFileURL
        let sourceValues = try values(
            for: source,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard sourceValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        try validateDirectory(destinationDirectory, fileManager: fileManager)
        try validateNoSymbolicLinks(in: source, fileManager: fileManager)

        if sourceValues.isDirectory == true {
            let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
            let destinationPath = destinationDirectory.path.hasSuffix("/")
                ? destinationDirectory.path
                : destinationDirectory.path + "/"
            guard destinationDirectory.path != source.path,
                  !destinationPath.hasPrefix(sourcePath) else {
                throw FileManagerOperationError.recursiveDestination
            }
        }

        let requestedDestination = destinationDirectory.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: sourceValues.isDirectory == true
        )
        if mode == .move,
           source.standardizedFileURL == requestedDestination.standardizedFileURL {
            return FileTransferResult(
                sourceURL: source,
                destinationURL: requestedDestination,
                disposition: .moved
            )
        }
        let destinationExists = fileManager.fileExists(atPath: requestedDestination.path)
        let destination: URL
        let replacing: Bool
        if destinationExists {
            switch conflictPolicy {
            case .fail:
                throw FileManagerOperationError.itemAlreadyExists
            case .replace:
                destination = requestedDestination
                replacing = true
            case .keepBoth:
                destination = uniqueDestinationURL(
                    for: requestedDestination,
                    isDirectory: sourceValues.isDirectory == true,
                    fileManager: fileManager
                )
                replacing = false
            }
        } else {
            destination = requestedDestination
            replacing = false
        }

        do {
            switch mode {
            case .copy:
                try copyItemSafely(
                    source,
                    to: destination,
                    replacing: replacing,
                    fileManager: fileManager
                )
            case .move:
                try moveItemSafely(
                    source,
                    to: destination,
                    replacing: replacing,
                    fileManager: fileManager
                )
            }
        } catch let error as FileManagerOperationError {
            throw error
        } catch {
            throw mode == .copy
                ? FileManagerOperationError.cannotCopy
                : FileManagerOperationError.cannotMove
        }

        let disposition: FileTransferDisposition
        if replacing {
            disposition = .replaced
        } else if destination != requestedDestination {
            disposition = .renamed
        } else {
            disposition = mode == .copy ? .copied : .moved
        }
        return FileTransferResult(
            sourceURL: source,
            destinationURL: destination,
            disposition: disposition
        )
    }

    static func createZIPArchive(
        containing sourceURLs: [URL],
        named rawName: String,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> FileArchiveResult {
        try validateDirectory(directoryURL, fileManager: fileManager)
        var name = try validatedName(rawName)
        if (name as NSString).pathExtension.lowercased() != "zip" {
            name += ".zip"
        }
        let destination = directoryURL.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileManagerOperationError.itemAlreadyExists
        }
        do {
            let result = try ZIPArchiveWriter.write(
                items: sourceURLs,
                to: destination,
                fileManager: fileManager
            )
            return FileArchiveResult(
                archiveURL: destination,
                entryCount: result.entryCount,
                sourceBytes: result.sourceBytes
            )
        } catch let error as ZIPArchiveWriterError {
            switch error {
            case .symbolicLinkUnsupported:
                throw FileManagerOperationError.symbolicLinkUnsupported
            case .emptySelection, .invalidSource, .duplicateEntry, .archiveTooLarge, .writeFailed:
                throw FileManagerOperationError.cannotArchive
            }
        } catch {
            throw FileManagerOperationError.cannotArchive
        }
    }

    static func importFile(
        _ sourceURL: URL,
        into directoryURL: URL,
        replaceExisting: Bool,
        fileManager: FileManager = .default
    ) throws -> FileImportResult {
        let sourceValues = try values(
            for: sourceURL,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard sourceValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        guard sourceValues.isDirectory != true else {
            throw FileManagerOperationError.sourceIsDirectory
        }
        let destinationURL = try destinationURL(
            named: sourceURL.lastPathComponent,
            in: directoryURL,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard replaceExisting else {
                throw FileManagerOperationError.itemAlreadyExists
            }
            let destinationValues = try values(
                for: destinationURL,
                missingError: .destinationMissing,
                fileManager: fileManager
            )
            guard destinationValues.isSymbolicLink != true else {
                throw FileManagerOperationError.symbolicLinkUnsupported
            }
            guard destinationValues.isDirectory != true else {
                throw FileManagerOperationError.destinationIsDirectory
            }
            do {
                let result = try FileReplacementService.replace(
                    target: destinationURL,
                    with: sourceURL,
                    fileManager: fileManager
                )
                return FileImportResult(
                    destinationURL: destinationURL,
                    byteCount: result.byteCount,
                    disposition: .replaced
                )
            } catch let error as FileReplacementError {
                switch error {
                case .sourceMissing: throw FileManagerOperationError.sourceMissing
                case .sourceIsDirectory: throw FileManagerOperationError.sourceIsDirectory
                case .sourceTooLarge: throw FileManagerOperationError.sourceTooLarge
                case .symbolicLinkUnsupported: throw FileManagerOperationError.symbolicLinkUnsupported
                default: throw FileManagerOperationError.cannotImport
                }
            } catch {
                throw FileManagerOperationError.cannotImport
            }
        }

        let stagingURL = directoryURL.appendingPathComponent(
            ".3105-import-\(UUID().uuidString)",
            isDirectory: false
        )
        try createExclusiveFile(
            at: stagingURL,
            existingError: .cannotImport,
            failureError: .cannotImport
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let copiedByteCount = try copyFile(
            from: sourceURL,
            to: stagingURL
        )
        guard renamex_np(
            stagingURL.path,
            destinationURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                throw FileManagerOperationError.itemAlreadyExists
            }
            throw FileManagerOperationError.cannotImport
        }
        return FileImportResult(
            destinationURL: destinationURL,
            byteCount: copiedByteCount,
            disposition: .imported
        )
    }

    static func extractZIPArchive(
        _ archiveURL: URL,
        into directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> ZIPArchiveExtractionResult {
        do {
            return try ZIPArchiveExtractor.extract(
                archiveURL: archiveURL,
                into: directoryURL,
                fileManager: fileManager
            )
        } catch let error as ZIPArchiveExtractorError {
            switch error {
            case .symbolicLinkUnsupported:
                throw FileManagerOperationError.symbolicLinkUnsupported
            case .invalidArchive:
                throw FileManagerOperationError.unsafeArchive
            case .insufficientSpace:
                throw FileManagerOperationError.insufficientSpace
            case .extractionFailed:
                throw FileManagerOperationError.cannotExtract
            }
        } catch {
            throw FileManagerOperationError.cannotExtract
        }
    }

    private static func validateDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) throws {
        let directoryValues = try values(
            for: directoryURL,
            missingError: .destinationMissing,
            fileManager: fileManager
        )
        guard directoryValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        guard directoryValues.isDirectory == true else {
            throw FileManagerOperationError.destinationNotDirectory
        }
    }

    private static func validateNoSymbolicLinks(
        in sourceURL: URL,
        fileManager: FileManager
    ) throws {
        let rootValues = try values(
            for: sourceURL,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard rootValues.isSymbolicLink != true else {
            throw FileManagerOperationError.symbolicLinkUnsupported
        }
        guard rootValues.isDirectory == true else { return }
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw FileManagerOperationError.sourceMissing
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw FileManagerOperationError.symbolicLinkUnsupported
            }
        }
        guard !enumerationFailed else {
            throw FileManagerOperationError.sourceMissing
        }
    }

    private static func uniqueDestinationURL(
        for requestedURL: URL,
        isDirectory: Bool,
        fileManager: FileManager
    ) -> URL {
        let directory = requestedURL.deletingLastPathComponent()
        let originalName = requestedURL.lastPathComponent
        let pathExtension = isDirectory ? "" : (originalName as NSString).pathExtension
        let baseName: String
        if pathExtension.isEmpty {
            baseName = originalName
        } else {
            baseName = (originalName as NSString).deletingPathExtension
        }
        var suffix = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: isDirectory)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private static func copyItemSafely(
        _ sourceURL: URL,
        to destinationURL: URL,
        replacing: Bool,
        fileManager: FileManager
    ) throws {
        let staging = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.copyItem(at: sourceURL, to: staging)
            try installStagingItem(
                staging,
                at: destinationURL,
                replacing: replacing,
                fileManager: fileManager
            )
        } catch let error as FileManagerOperationError {
            throw error
        } catch {
            throw FileManagerOperationError.cannotCopy
        }
    }

    private static func moveItemSafely(
        _ sourceURL: URL,
        to destinationURL: URL,
        replacing: Bool,
        fileManager: FileManager
    ) throws {
        if !replacing {
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return
            } catch {
                do {
                    try copyItemSafely(
                        sourceURL,
                        to: destinationURL,
                        replacing: false,
                        fileManager: fileManager
                    )
                    try fileManager.removeItem(at: sourceURL)
                    return
                } catch {
                    try? fileManager.removeItem(at: destinationURL)
                    throw FileManagerOperationError.cannotMove
                }
            }
        }

        let backup = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-displaced-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: destinationURL, to: backup)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                // Installing the requested item is the operation's commit point.
                // A stale backup is safer than reporting a failed move after the
                // source has already changed locations.
                try? fileManager.removeItem(at: backup)
            } catch {
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.moveItem(at: backup, to: destinationURL)
                }
                throw FileManagerOperationError.cannotMove
            }
        } catch let error as FileManagerOperationError {
            throw error
        } catch {
            throw FileManagerOperationError.cannotMove
        }
    }

    private static func installStagingItem(
        _ stagingURL: URL,
        at destinationURL: URL,
        replacing: Bool,
        fileManager: FileManager
    ) throws {
        guard replacing else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return
        }
        let backup = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-displaced-\(UUID().uuidString)")
        try fileManager.moveItem(at: destinationURL, to: backup)
        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            try? fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.moveItem(at: backup, to: destinationURL)
            }
            throw FileManagerOperationError.cannotCopy
        }
    }

    private static func values(
        for url: URL,
        missingError: FileManagerOperationError,
        fileManager: FileManager
    ) throws -> URLResourceValues {
        guard fileManager.fileExists(atPath: url.path) else { throw missingError }
        do {
            return try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw missingError
        }
    }

    private static func copyFile(from sourceURL: URL, to stagingURL: URL) throws -> Int64 {
        do {
            let source = try FileHandle(forReadingFrom: sourceURL)
            let staging = try FileHandle(forWritingTo: stagingURL)
            defer {
                try? source.close()
                try? staging.close()
            }
            var copiedByteCount: Int64 = 0
            while let data = try source.read(upToCount: copyChunkSize), !data.isEmpty {
                let (nextCount, overflow) = copiedByteCount.addingReportingOverflow(Int64(data.count))
                guard !overflow else {
                    throw FileManagerOperationError.sourceTooLarge
                }
                copiedByteCount = nextCount
                try staging.write(contentsOf: data)
            }
            try staging.synchronize()
            return copiedByteCount
        } catch let error as FileManagerOperationError {
            throw error
        } catch {
            throw FileManagerOperationError.cannotImport
        }
    }

    private static func createExclusiveFile(
        at url: URL,
        existingError: FileManagerOperationError,
        failureError: FileManagerOperationError
    ) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw existingError }
            throw failureError
        }
        guard close(descriptor) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw failureError
        }
    }
}
