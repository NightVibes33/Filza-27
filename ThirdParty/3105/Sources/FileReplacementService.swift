import Foundation
import Darwin
import UniformTypeIdentifiers

enum ReplacementPickerPolicy {
    static let allowedContentTypes: [UTType] = [.data]
    static let copiesSelectedDocument = true
    static let presentationDelay: TimeInterval = 0.35

    static func accepts(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .folder)
    }
}

struct FileReplacementSelection: Equatable {
    let targetURL: URL
    let targetName: String
    let sourceURL: URL
}

struct FileReplacementRequest: Identifiable, Equatable {
    let id: UUID
    let targetURL: URL
    let targetName: String

    init(id: UUID = UUID(), targetURL: URL, targetName: String) {
        self.id = id
        self.targetURL = targetURL
        self.targetName = targetName
    }

    func selection(from urls: [URL]) throws -> FileReplacementSelection {
        guard let sourceURL = urls.first else {
            throw FileReplacementError.sourceMissing
        }
        return FileReplacementSelection(
            targetURL: targetURL,
            targetName: targetName,
            sourceURL: sourceURL
        )
    }
}

enum FileReplacementError: Error, Equatable, LocalizedError {
    case targetMissing
    case sourceMissing
    case targetIsDirectory
    case sourceIsDirectory
    case sameFile
    case symbolicLinkUnsupported
    case sourceTooLarge
    case replacementFailed

    var errorDescription: String? {
        switch self {
        case .targetMissing: return "The target file no longer exists."
        case .sourceMissing: return "The selected replacement file is unavailable."
        case .targetIsDirectory: return "Folders cannot be replaced with this action."
        case .sourceIsDirectory: return "Select a file, not a folder."
        case .sameFile: return "A file cannot replace itself."
        case .symbolicLinkUnsupported: return "Symbolic links are not supported."
        case .sourceTooLarge: return "The selected file is too large."
        case .replacementFailed: return "The file could not be replaced safely."
        }
    }
}

struct FileReplacementResult: Equatable {
    let targetURL: URL
    let byteCount: Int64
}

enum FileReplacementService {
    static let maximumByteCount: Int64 = 512 * 1_024 * 1_024
    private static let chunkSize = 1_024 * 1_024

    static func replace(
        target targetURL: URL,
        with sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> FileReplacementResult {
        let targetValues = try values(
            for: targetURL,
            missingError: .targetMissing,
            fileManager: fileManager
        )
        let sourceValues = try values(
            for: sourceURL,
            missingError: .sourceMissing,
            fileManager: fileManager
        )
        guard targetValues.isSymbolicLink != true,
              sourceValues.isSymbolicLink != true else {
            throw FileReplacementError.symbolicLinkUnsupported
        }
        guard targetValues.isDirectory != true else {
            throw FileReplacementError.targetIsDirectory
        }
        guard sourceValues.isDirectory != true else {
            throw FileReplacementError.sourceIsDirectory
        }
        guard targetURL.standardizedFileURL.resolvingSymlinksInPath()
                != sourceURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw FileReplacementError.sameFile
        }
        if let size = sourceValues.fileSize, Int64(size) > maximumByteCount {
            throw FileReplacementError.sourceTooLarge
        }

        let targetAttributes = try fileManager.attributesOfItem(atPath: targetURL.path)
        let stagingURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-replacement-\(UUID().uuidString)")
        let stagingAttributes = retainedAttributes(from: targetAttributes)
        guard fileManager.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: stagingAttributes
        ) else {
            throw FileReplacementError.replacementFailed
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        var copied: Int64 = 0
        do {
            let source = try FileHandle(forReadingFrom: sourceURL)
            let staging = try FileHandle(forWritingTo: stagingURL)
            defer {
                try? source.close()
                try? staging.close()
            }
            while let data = try source.read(upToCount: chunkSize), !data.isEmpty {
                copied += Int64(data.count)
                guard copied <= maximumByteCount else {
                    throw FileReplacementError.sourceTooLarge
                }
                try staging.write(contentsOf: data)
            }
            try staging.synchronize()
        } catch let error as FileReplacementError {
            throw error
        } catch {
            throw FileReplacementError.replacementFailed
        }

        let currentValues = try values(
            for: targetURL,
            missingError: .targetMissing,
            fileManager: fileManager
        )
        guard currentValues.isSymbolicLink != true,
              currentValues.isDirectory != true else {
            throw FileReplacementError.symbolicLinkUnsupported
        }
        guard rename(stagingURL.path, targetURL.path) == 0 else {
            throw FileReplacementError.replacementFailed
        }
        return FileReplacementResult(targetURL: targetURL, byteCount: copied)
    }

    private static func values(
        for url: URL,
        missingError: FileReplacementError,
        fileManager: FileManager
    ) throws -> URLResourceValues {
        guard fileManager.fileExists(atPath: url.path) else { throw missingError }
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw missingError
        }
    }

    private static func retainedAttributes(
        from attributes: [FileAttributeKey: Any]
    ) -> [FileAttributeKey: Any] {
        var result: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] {
            result[.posixPermissions] = permissions
        }
        if let protection = attributes[.protectionKey] {
            result[.protectionKey] = protection
        }
        return result
    }
}
