import Foundation

@_silgen_name("wallpaper_zip_extract_entry")
private func wallpaperZIPExtractEntry(
    _ archivePath: UnsafePointer<CChar>,
    _ dataOffset: UInt64,
    _ compressedSize: UInt64,
    _ compressionMethod: UInt16,
    _ destinationPath: UnsafePointer<CChar>,
    _ expectedSize: UInt64,
    _ expectedCRC32: UInt32
) -> Int32

struct SecureZIPExtraction: Equatable {
    let fileCount: Int
    let expandedBytes: Int64
}

enum SecureZIPArchive {
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50

    static func extract(
        archiveURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> SecureZIPExtraction {
        guard archiveURL.isFileURL,
              fileManager.fileExists(atPath: archiveURL.path) else {
            throw WallpaperLabError.unsupportedPackage
        }
        let archiveValues = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard archiveValues.isRegularFile == true,
              archiveValues.isSymbolicLink != true else {
            throw WallpaperLabError.symbolicLinkUnsupported
        }
        let archiveSize = Int64(archiveValues.fileSize ?? 0)
        guard archiveSize >= 22,
              archiveSize <= WallpaperLabLimits.maximumArchiveBytes else {
            throw WallpaperLabError.packageTooLarge
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw WallpaperLabError.unsafeArchive
        }

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let entries = try readEntries(handle: handle, archiveSize: UInt64(archiveSize))
        let expandedBytes = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        guard entries.count <= WallpaperLabLimits.maximumEntryCount,
              expandedBytes <= UInt64(WallpaperLabLimits.maximumExpandedBytes) else {
            throw WallpaperLabError.packageTooLarge
        }

        do {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: false
            )
            for entry in entries {
                let targetURL = try destination(
                    for: entry.pathComponents,
                    root: destinationURL,
                    isDirectory: entry.isDirectory
                )
                if entry.isDirectory {
                    try fileManager.createDirectory(
                        at: targetURL,
                        withIntermediateDirectories: true
                    )
                    continue
                }
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let status = archiveURL.path.withCString { archivePath in
                    targetURL.path.withCString { destinationPath in
                        wallpaperZIPExtractEntry(
                            archivePath,
                            entry.dataOffset,
                            entry.compressedSize,
                            entry.compressionMethod,
                            destinationPath,
                            entry.uncompressedSize,
                            entry.crc32
                        )
                    }
                }
                guard status == 0 else { throw WallpaperLabError.unsafeArchive }
            }
        } catch let error as WallpaperLabError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw WallpaperLabError.unsafeArchive
        }

        return SecureZIPExtraction(
            fileCount: entries.filter { !$0.isDirectory }.count,
            expandedBytes: Int64(expandedBytes)
        )
    }

    private static func readEntries(
        handle: FileHandle,
        archiveSize: UInt64
    ) throws -> [Entry] {
        let tailSize = min(archiveSize, 65_557)
        let tailOffset = archiveSize - tailSize
        let tail = try read(handle: handle, offset: tailOffset, count: Int(tailSize))
        guard let relativeEndOffset = lastSignature(endSignature, in: tail) else {
            throw WallpaperLabError.unsupportedPackage
        }
        let endOffset = tailOffset + UInt64(relativeEndOffset)
        guard relativeEndOffset + 22 <= tail.count else {
            throw WallpaperLabError.unsafeArchive
        }
        let end = tail.subdata(in: relativeEndOffset..<min(tail.count, relativeEndOffset + 22))
        let diskNumber = u16(end, 4)
        let centralDisk = u16(end, 6)
        let diskEntries = u16(end, 8)
        let entryCount = u16(end, 10)
        let centralSize = u32(end, 12)
        let centralOffset = u32(end, 16)
        let commentLength = u16(end, 20)
        guard diskNumber == 0,
              centralDisk == 0,
              diskEntries == entryCount,
              entryCount != 0xffff,
              centralSize != 0xffff_ffff,
              centralOffset != 0xffff_ffff,
              Int(entryCount) <= WallpaperLabLimits.maximumEntryCount,
              relativeEndOffset + 22 + Int(commentLength) == tail.count,
              UInt64(centralOffset) + UInt64(centralSize) == endOffset else {
            throw WallpaperLabError.unsafeArchive
        }

        var entries: [Entry] = []
        var seenPaths = Set<String>()
        var cursor = UInt64(centralOffset)
        let centralEnd = cursor + UInt64(centralSize)
        var totalExpanded: UInt64 = 0

        for _ in 0..<Int(entryCount) {
            let header = try read(handle: handle, offset: cursor, count: 46)
            guard u32(header, 0) == centralHeaderSignature else {
                throw WallpaperLabError.unsafeArchive
            }
            let flags = u16(header, 8)
            let method = u16(header, 10)
            let checksum = u32(header, 16)
            let compressedSize = u32(header, 20)
            let uncompressedSize = u32(header, 24)
            let nameLength = Int(u16(header, 28))
            let extraLength = Int(u16(header, 30))
            let commentLength = Int(u16(header, 32))
            let diskStart = u16(header, 34)
            let externalAttributes = u32(header, 38)
            let localOffset = u32(header, 42)
            let variableCount = nameLength + extraLength + commentLength
            guard nameLength > 0,
                  nameLength <= WallpaperLabLimits.maximumPathBytes,
                  cursor + 46 + UInt64(variableCount) <= centralEnd,
                  flags & 0x0001 == 0,
                  method == 0 || method == 8,
                  diskStart == 0,
                  compressedSize != 0xffff_ffff,
                  uncompressedSize != 0xffff_ffff,
                  localOffset != 0xffff_ffff,
                  UInt64(uncompressedSize) <= UInt64(WallpaperLabLimits.maximumEntryBytes) else {
                throw WallpaperLabError.unsafeArchive
            }

            let nameData = try read(handle: handle, offset: cursor + 46, count: nameLength)
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw WallpaperLabError.unsafeArchive
            }
            let mode = UInt16((externalAttributes >> 16) & 0xffff)
            let fileType = mode & 0o170000
            guard fileType != 0o120000 else {
                throw WallpaperLabError.symbolicLinkUnsupported
            }
            let nameIsDirectory = rawName.hasSuffix("/")
            guard fileType == 0 || fileType == 0o100000 || fileType == 0o040000 else {
                throw WallpaperLabError.unsafeArchive
            }
            let isDirectory = nameIsDirectory || fileType == 0o040000
            guard isDirectory || fileType != 0o040000 else {
                throw WallpaperLabError.unsafeArchive
            }
            let components = try safeComponents(rawName, isDirectory: isDirectory)
            let normalized = components.joined(separator: "/").lowercased()
            guard seenPaths.insert(normalized).inserted else {
                throw WallpaperLabError.unsafeArchive
            }
            totalExpanded += UInt64(uncompressedSize)
            guard totalExpanded <= UInt64(WallpaperLabLimits.maximumExpandedBytes) else {
                throw WallpaperLabError.packageTooLarge
            }

            let localHeader = try read(handle: handle, offset: UInt64(localOffset), count: 30)
            guard u32(localHeader, 0) == localHeaderSignature,
                  u16(localHeader, 6) & 0x0001 == 0,
                  u16(localHeader, 8) == method else {
                throw WallpaperLabError.unsafeArchive
            }
            let localNameLength = UInt64(u16(localHeader, 26))
            let localExtraLength = UInt64(u16(localHeader, 28))
            let dataOffset = UInt64(localOffset) + 30 + localNameLength + localExtraLength
            guard dataOffset <= UInt64(centralOffset),
                  UInt64(compressedSize) <= UInt64(centralOffset) - dataOffset else {
                throw WallpaperLabError.unsafeArchive
            }

            entries.append(
                Entry(
                    pathComponents: components,
                    isDirectory: isDirectory,
                    compressionMethod: method,
                    crc32: checksum,
                    compressedSize: UInt64(compressedSize),
                    uncompressedSize: UInt64(uncompressedSize),
                    dataOffset: dataOffset
                )
            )
            cursor += 46 + UInt64(variableCount)
        }
        guard cursor == centralEnd else { throw WallpaperLabError.unsafeArchive }
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
              rawName.utf8.count <= WallpaperLabLimits.maximumPathBytes else {
            throw WallpaperLabError.unsafeArchive
        }
        var components = rawName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if isDirectory, components.last == "" { components.removeLast() }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WallpaperLabError.unsafeArchive
        }
        return components
    }

    private static func destination(
        for components: [String],
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
        guard WallpaperLayoutScanner.isContained(result, in: root) else {
            throw WallpaperLabError.unsafeArchive
        }
        return result
    }

    private static func read(
        handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw WallpaperLabError.unsafeArchive }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw WallpaperLabError.unsafeArchive
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

private struct Entry {
    let pathComponents: [String]
    let isDirectory: Bool
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let dataOffset: UInt64
}
