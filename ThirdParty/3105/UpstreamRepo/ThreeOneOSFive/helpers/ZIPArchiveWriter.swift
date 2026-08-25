import Foundation

enum ZIPArchiveWriterError: Error, Equatable {
    case emptySelection
    case invalidSource
    case symbolicLinkUnsupported
    case duplicateEntry
    case archiveTooLarge
    case writeFailed
}

struct ZIPArchiveWriteResult: Equatable {
    let entryCount: Int
    let sourceBytes: Int64
}

/// A dependency-free ZIP writer for the file browser. Entries are stored
/// without compression so content can be streamed instead of loaded into RAM.
enum ZIPArchiveWriter {
    private struct Entry {
        let sourceURL: URL
        let archivePath: String
        let isDirectory: Bool
        let byteCount: UInt32
        let crc32: UInt32
        let modifiedTime: UInt16
        let modifiedDate: UInt16
        let localHeaderOffset: UInt32
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let utf8Flag: UInt16 = 1 << 11
    private static let chunkSize = 1_024 * 1_024

    static func write(
        items sourceURLs: [URL],
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> ZIPArchiveWriteResult {
        guard !sourceURLs.isEmpty else { throw ZIPArchiveWriterError.emptySelection }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ZIPArchiveWriterError.writeFailed
        }

        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".3105-archive-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw ZIPArchiveWriterError.writeFailed
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        do {
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }
            var entries: [Entry] = []
            var seenPaths = Set<String>()
            var sourceBytes: Int64 = 0

            for sourceURL in sourceURLs {
                try appendTree(
                    rootedAt: sourceURL.standardizedFileURL,
                    archiveRootName: sourceURL.lastPathComponent,
                    handle: handle,
                    entries: &entries,
                    seenPaths: &seenPaths,
                    sourceBytes: &sourceBytes,
                    fileManager: fileManager
                )
            }

            guard entries.count <= Int(UInt16.max) else {
                throw ZIPArchiveWriterError.archiveTooLarge
            }
            let centralOffset = try currentOffset(handle)
            for entry in entries {
                try writeCentralHeader(entry, to: handle)
            }
            let endOffset = try currentOffset(handle)
            let centralSize = endOffset - centralOffset
            guard centralOffset <= UInt64(UInt32.max), centralSize <= UInt64(UInt32.max) else {
                throw ZIPArchiveWriterError.archiveTooLarge
            }
            try writeEndRecord(
                entryCount: UInt16(entries.count),
                centralSize: UInt32(centralSize),
                centralOffset: UInt32(centralOffset),
                to: handle
            )
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return ZIPArchiveWriteResult(entryCount: entries.count, sourceBytes: sourceBytes)
        } catch let error as ZIPArchiveWriterError {
            throw error
        } catch {
            throw ZIPArchiveWriterError.writeFailed
        }
    }

    private static func appendTree(
        rootedAt sourceURL: URL,
        archiveRootName: String,
        handle: FileHandle,
        entries: inout [Entry],
        seenPaths: inout Set<String>,
        sourceBytes: inout Int64,
        fileManager: FileManager
    ) throws {
        let rootValues = try safeValues(sourceURL)
        guard rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw ZIPArchiveWriterError.invalidSource
        }
        if rootValues.isDirectory == true {
            try append(
                sourceURL,
                archivePath: archiveRootName + "/",
                values: rootValues,
                handle: handle,
                entries: &entries,
                seenPaths: &seenPaths,
                sourceBytes: &sourceBytes
            )
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else {
                throw ZIPArchiveWriterError.invalidSource
            }
            while let child = enumerator.nextObject() as? URL {
                let values = try safeValues(child)
                if values.isDirectory != true && values.isRegularFile != true {
                    throw ZIPArchiveWriterError.invalidSource
                }
                let relativePath = child.pathComponents
                    .suffix(enumerator.level)
                    .joined(separator: "/")
                guard !relativePath.isEmpty else {
                    throw ZIPArchiveWriterError.invalidSource
                }
                var archivePath = archiveRootName + "/" + relativePath
                if values.isDirectory == true { archivePath += "/" }
                try append(
                    child,
                    archivePath: archivePath,
                    values: values,
                    handle: handle,
                    entries: &entries,
                    seenPaths: &seenPaths,
                    sourceBytes: &sourceBytes
                )
            }
            guard !enumerationFailed else {
                throw ZIPArchiveWriterError.invalidSource
            }
        } else {
            try append(
                sourceURL,
                archivePath: archiveRootName,
                values: rootValues,
                handle: handle,
                entries: &entries,
                seenPaths: &seenPaths,
                sourceBytes: &sourceBytes
            )
        }
    }

    private static func append(
        _ sourceURL: URL,
        archivePath: String,
        values: URLResourceValues,
        handle: FileHandle,
        entries: inout [Entry],
        seenPaths: inout Set<String>,
        sourceBytes: inout Int64
    ) throws {
        guard let nameData = archivePath.data(using: .utf8),
              !nameData.isEmpty,
              nameData.count <= Int(UInt16.max),
              !archivePath.hasPrefix("/"),
              !archivePath.contains("\\"),
              !archivePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw ZIPArchiveWriterError.invalidSource
        }
        guard seenPaths.insert(archivePath).inserted else {
            throw ZIPArchiveWriterError.duplicateEntry
        }

        let isDirectory = values.isDirectory == true
        let fileSize = isDirectory ? 0 : Int64(values.fileSize ?? 0)
        guard fileSize >= 0, fileSize <= Int64(UInt32.max) else {
            throw ZIPArchiveWriterError.archiveTooLarge
        }
        let offset = try currentOffset(handle)
        guard offset <= UInt64(UInt32.max) else {
            throw ZIPArchiveWriterError.archiveTooLarge
        }
        let checksum = isDirectory ? 0 : try crc32(of: sourceURL)
        let date = dosDate(values.contentModificationDate ?? Date())
        let entry = Entry(
            sourceURL: sourceURL,
            archivePath: archivePath,
            isDirectory: isDirectory,
            byteCount: UInt32(fileSize),
            crc32: checksum,
            modifiedTime: date.time,
            modifiedDate: date.date,
            localHeaderOffset: UInt32(offset)
        )
        try writeLocalHeader(entry, nameData: nameData, to: handle)
        if !isDirectory {
            try stream(sourceURL, to: handle)
            let (nextBytes, overflow) = sourceBytes.addingReportingOverflow(fileSize)
            guard !overflow else { throw ZIPArchiveWriterError.archiveTooLarge }
            sourceBytes = nextBytes
        }
        entries.append(entry)
    }

    private static var resourceKeys: [URLResourceKey] {
        [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    }

    private static func safeValues(_ url: URL) throws -> URLResourceValues {
        do {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isSymbolicLink != true else {
                throw ZIPArchiveWriterError.symbolicLinkUnsupported
            }
            return values
        } catch let error as ZIPArchiveWriterError {
            throw error
        } catch {
            throw ZIPArchiveWriterError.invalidSource
        }
    }

    private static func writeLocalHeader(
        _ entry: Entry,
        nameData: Data,
        to handle: FileHandle
    ) throws {
        var header = Data()
        header.appendLittleEndian(localHeaderSignature)
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(utf8Flag)
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(entry.modifiedTime)
        header.appendLittleEndian(entry.modifiedDate)
        header.appendLittleEndian(entry.crc32)
        header.appendLittleEndian(entry.byteCount)
        header.appendLittleEndian(entry.byteCount)
        header.appendLittleEndian(UInt16(nameData.count))
        header.appendLittleEndian(UInt16(0))
        header.append(nameData)
        try handle.write(contentsOf: header)
    }

    private static func writeCentralHeader(_ entry: Entry, to handle: FileHandle) throws {
        guard let nameData = entry.archivePath.data(using: .utf8) else {
            throw ZIPArchiveWriterError.invalidSource
        }
        var header = Data()
        header.appendLittleEndian(centralHeaderSignature)
        header.appendLittleEndian(UInt16(0x0314))
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(utf8Flag)
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(entry.modifiedTime)
        header.appendLittleEndian(entry.modifiedDate)
        header.appendLittleEndian(entry.crc32)
        header.appendLittleEndian(entry.byteCount)
        header.appendLittleEndian(entry.byteCount)
        header.appendLittleEndian(UInt16(nameData.count))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt16(0))
        let permissions: UInt32 = entry.isDirectory ? 0o040755 : 0o100600
        header.appendLittleEndian((permissions << 16) | (entry.isDirectory ? 0x10 : 0))
        header.appendLittleEndian(entry.localHeaderOffset)
        header.append(nameData)
        try handle.write(contentsOf: header)
    }

    private static func writeEndRecord(
        entryCount: UInt16,
        centralSize: UInt32,
        centralOffset: UInt32,
        to handle: FileHandle
    ) throws {
        var record = Data()
        record.appendLittleEndian(endSignature)
        record.appendLittleEndian(UInt16(0))
        record.appendLittleEndian(UInt16(0))
        record.appendLittleEndian(entryCount)
        record.appendLittleEndian(entryCount)
        record.appendLittleEndian(centralSize)
        record.appendLittleEndian(centralOffset)
        record.appendLittleEndian(UInt16(0))
        try handle.write(contentsOf: record)
    }

    private static func stream(_ sourceURL: URL, to destination: FileHandle) throws {
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
            try destination.write(contentsOf: chunk)
        }
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = 0xffff_ffff
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for byte in chunk {
                let index = Int((crc ^ UInt32(byte)) & 0xff)
                crc = crcTable[index] ^ (crc >> 8)
            }
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    private static func currentOffset(_ handle: FileHandle) throws -> UInt64 {
        try handle.offset()
    }

    private static func dosDate(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            in: TimeZone.current,
            from: min(max(date, Date(timeIntervalSince1970: 315_532_800)), Date(timeIntervalSince1970: 4_354_819_198))
        )
        let year = UInt16(max(1980, min(2107, components.year ?? 1980)) - 1980)
        let month = UInt16(max(1, min(12, components.month ?? 1)))
        let day = UInt16(max(1, min(31, components.day ?? 1)))
        let hour = UInt16(max(0, min(23, components.hour ?? 0)))
        let minute = UInt16(max(0, min(59, components.minute ?? 0)))
        let second = UInt16(max(0, min(59, components.second ?? 0)) / 2)
        return (
            time: (hour << 11) | (minute << 5) | second,
            date: (year << 9) | (month << 5) | day
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
