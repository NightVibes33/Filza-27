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
    case sourceTooLarge
    case cannotCreate
    case cannotRename
    case cannotDelete
    case cannotImport

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
        case .sourceTooLarge: return "The selected file is too large."
        case .cannotCreate: return "The item could not be created."
        case .cannotRename: return "The item could not be renamed."
        case .cannotDelete: return "The item could not be deleted."
        case .cannotImport: return "The file could not be imported safely."
        }
    }
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
    static let maximumImportByteCount = FileReplacementService.maximumByteCount
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
        if let sourceSize = sourceValues.fileSize,
           Int64(sourceSize) > maximumImportByteCount {
            throw FileManagerOperationError.sourceTooLarge
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
                copiedByteCount += Int64(data.count)
                guard copiedByteCount <= maximumImportByteCount else {
                    throw FileManagerOperationError.sourceTooLarge
                }
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
