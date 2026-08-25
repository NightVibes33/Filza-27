import Foundation

@_silgen_name("wallpaper_zip_extract_entry")
private func browserZIPExtractEntry(
    _ archivePath: UnsafePointer<CChar>,
    _ dataOffset: UInt64,
    _ compressedSize: UInt64,
    _ compressionMethod: UInt16,
    _ destinationPath: UnsafePointer<CChar>,
    _ expectedSize: UInt64,
    _ expectedCRC32: UInt32
) -> Int32

enum ZIPArchiveExtractorError: Error, Equatable {
    case invalidArchive
    case symbolicLinkUnsupported
    case insufficientSpace
    case extractionFailed
}

struct ZIPArchiveExtractionResult: Equatable {
    let destinationURL: URL
    let fileCount: Int
    let expandedBytes: Int64
}

enum ZIPArchiveExtractor {
    private struct Entry {
        let components: [String]
        let isDirectory: Bool
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let dataOffset: UInt64
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let diskReserveBytes: Int64 = 64 * 1_024 * 1_024

    static func extract(
        archiveURL: URL,
        into directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> ZIPArchiveExtractionResult {
        let archive = archiveURL.standardizedFileURL
        let destinationDirectory = directoryURL.standardizedFileURL
        let archiveValues = try archive.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard archiveValues.isRegularFile == true,
              archiveValues.isDirectory != true,
              archiveValues.isSymbolicLink != true,
              let archiveSizeValue = archiveValues.fileSize,
              archiveSizeValue >= 22 else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        let directoryValues = try destinationDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw ZIPArchiveExtractorError.extractionFailed
        }

        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let entries = try readEntries(handle: handle, archiveSize: UInt64(archiveSizeValue))
        var expandedBytes: UInt64 = 0
        for entry in entries {
            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= UInt64(Int64.max) else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            expandedBytes = sum
        }
        if let available = directoryValues.volumeAvailableCapacityForImportantUsage,
           Int64(expandedBytes) > max(0, available - diskReserveBytes) {
            throw ZIPArchiveExtractorError.insufficientSpace
        }

        let destination = uniqueDestinationURL(
            for: archive,
            in: destinationDirectory,
            fileManager: fileManager
        )
        let staging = destinationDirectory.appendingPathComponent(
            ".3105-unzip-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for entry in entries {
                let target = try destinationURL(
                    components: entry.components,
                    root: staging,
                    isDirectory: entry.isDirectory
                )
                if entry.isDirectory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let status = archive.path.withCString { archivePath in
                    target.path.withCString { targetPath in
                        browserZIPExtractEntry(
                            archivePath,
                            entry.dataOffset,
                            entry.compressedSize,
                            entry.compressionMethod,
                            targetPath,
                            entry.uncompressedSize,
                            entry.crc32
                        )
                    }
                }
                guard status == 0 else {
                    throw ZIPArchiveExtractorError.extractionFailed
                }
            }
            try fileManager.moveItem(at: staging, to: destination)
            return ZIPArchiveExtractionResult(
                destinationURL: destination,
                fileCount: entries.filter { !$0.isDirectory }.count,
                expandedBytes: Int64(expandedBytes)
            )
        } catch let error as ZIPArchiveExtractorError {
            throw error
        } catch {
            throw ZIPArchiveExtractorError.extractionFailed
        }
    }

    private static func readEntries(
        handle: FileHandle,
        archiveSize: UInt64
    ) throws -> [Entry] {
        let tailSize = min(archiveSize, 65_557)
        let tailOffset = archiveSize - tailSize
        let tail = try read(handle: handle, offset: tailOffset, count: Int(tailSize))
        guard let relativeEndOffset = lastSignature(endSignature, in: tail),
              relativeEndOffset + 22 <= tail.count else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        let endOffset = tailOffset + UInt64(relativeEndOffset)
        let diskNumber = u16(tail, relativeEndOffset + 4)
        let centralDisk = u16(tail, relativeEndOffset + 6)
        let diskEntries = u16(tail, relativeEndOffset + 8)
        let entryCount = u16(tail, relativeEndOffset + 10)
        let centralSize = u32(tail, relativeEndOffset + 12)
        let centralOffset = u32(tail, relativeEndOffset + 16)
        let commentLength = Int(u16(tail, relativeEndOffset + 20))
        guard diskNumber == 0,
              centralDisk == 0,
              diskEntries == entryCount,
              entryCount != 0xffff,
              centralSize != 0xffff_ffff,
              centralOffset != 0xffff_ffff,
              relativeEndOffset + 22 + commentLength == tail.count,
              UInt64(centralOffset) + UInt64(centralSize) == endOffset else {
            throw ZIPArchiveExtractorError.invalidArchive
        }

        var entries: [Entry] = []
        var seen: [String: Bool] = [:]
        var cursor = UInt64(centralOffset)
        let centralEnd = cursor + UInt64(centralSize)
        for _ in 0..<Int(entryCount) {
            let header = try read(handle: handle, offset: cursor, count: 46)
            guard u32(header, 0) == centralHeaderSignature else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            let flags = u16(header, 8)
            let method = u16(header, 10)
            let checksum = u32(header, 16)
            let compressedSize = u32(header, 20)
            let uncompressedSize = u32(header, 24)
            let nameLength = Int(u16(header, 28))
            let extraLength = Int(u16(header, 30))
            let itemCommentLength = Int(u16(header, 32))
            let diskStart = u16(header, 34)
            let externalAttributes = u32(header, 38)
            let localOffset = u32(header, 42)
            let variableCount = nameLength + extraLength + itemCommentLength
            guard nameLength > 0,
                  cursor + 46 + UInt64(variableCount) <= centralEnd,
                  flags & 0x0001 == 0,
                  method == 0 || method == 8,
                  diskStart == 0,
                  compressedSize != 0xffff_ffff,
                  uncompressedSize != 0xffff_ffff,
                  localOffset != 0xffff_ffff else {
                throw ZIPArchiveExtractorError.invalidArchive
            }

            let nameData = try read(handle: handle, offset: cursor + 46, count: nameLength)
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            let mode = UInt16((externalAttributes >> 16) & 0xffff)
            let fileType = mode & 0o170000
            guard fileType != 0o120000 else {
                throw ZIPArchiveExtractorError.symbolicLinkUnsupported
            }
            guard fileType == 0 || fileType == 0o100000 || fileType == 0o040000 else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            let isDirectory = rawName.hasSuffix("/") || fileType == 0o040000
            let components = try safeComponents(rawName, isDirectory: isDirectory)
            let normalized = components.joined(separator: "/").lowercased()
            guard seen[normalized] == nil else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            for count in 1..<components.count {
                let parent = components.prefix(count).joined(separator: "/").lowercased()
                if seen[parent] == false { throw ZIPArchiveExtractorError.invalidArchive }
            }
            seen[normalized] = isDirectory

            let localHeader = try read(handle: handle, offset: UInt64(localOffset), count: 30)
            guard u32(localHeader, 0) == localHeaderSignature,
                  u16(localHeader, 6) & 0x0001 == 0,
                  u16(localHeader, 8) == method else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            let localNameLength = Int(u16(localHeader, 26))
            let localExtraLength = UInt64(u16(localHeader, 28))
            let localName = try read(
                handle: handle,
                offset: UInt64(localOffset) + 30,
                count: localNameLength
            )
            guard localName == nameData else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            let dataOffset = UInt64(localOffset) + 30 + UInt64(localNameLength) + localExtraLength
            guard dataOffset <= UInt64(centralOffset),
                  UInt64(compressedSize) <= UInt64(centralOffset) - dataOffset else {
                throw ZIPArchiveExtractorError.invalidArchive
            }
            entries.append(Entry(
                components: components,
                isDirectory: isDirectory,
                compressionMethod: method,
                crc32: checksum,
                compressedSize: UInt64(compressedSize),
                uncompressedSize: UInt64(uncompressedSize),
                dataOffset: dataOffset
            ))
            cursor += 46 + UInt64(variableCount)
        }
        guard cursor == centralEnd else { throw ZIPArchiveExtractorError.invalidArchive }
        return entries
    }

    private static func safeComponents(
        _ rawName: String,
        isDirectory: Bool
    ) throws -> [String] {
        guard !rawName.isEmpty,
              !rawName.hasPrefix("/"),
              !rawName.contains("\\"),
              !rawName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              rawName.utf8.count <= PatchPackageLimits.maximumPathBytes else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        var components = rawName.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        if isDirectory, components.last == "" { components.removeLast() }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        return components
    }

    private static func destinationURL(
        components: [String],
        root: URL,
        isDirectory: Bool
    ) throws -> URL {
        var result = root
        for (index, component) in components.enumerated() {
            result.appendPathComponent(
                component,
                isDirectory: isDirectory && index == components.count - 1
            )
        }
        let standardized = result.standardizedFileURL
        guard standardized.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        return standardized
    }

    private static func uniqueDestinationURL(
        for archiveURL: URL,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let base = (archiveURL.lastPathComponent as NSString).deletingPathExtension
        let safeBase = (try? FileManagerService.validatedName(base)) ?? "Archive"
        var candidate = directoryURL.appendingPathComponent(safeBase, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(safeBase) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func read(
        handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw ZIPArchiveExtractorError.invalidArchive }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZIPArchiveExtractorError.invalidArchive
        }
        return data
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for offset in stride(from: data.count - 4, through: 0, by: -1) {
            if u32(data, offset) == signature { return offset }
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
