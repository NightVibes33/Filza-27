import Foundation

enum FileBrowserSortOrder: String, CaseIterable, Identifiable {
    static let storageKey = "browser.sort.order"

    case nameAscending
    case nameDescending
    case sizeDescending
    case sizeAscending
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .nameAscending: return "browser.sort_name_ascending"
        case .nameDescending: return "browser.sort_name_descending"
        case .sizeDescending: return "browser.sort_size_descending"
        case .sizeAscending: return "browser.sort_size_ascending"
        case .newestFirst: return "browser.sort_newest"
        case .oldestFirst: return "browser.sort_oldest"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending: return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        case .sizeDescending: return "arrow.down"
        case .sizeAscending: return "arrow.up"
        case .newestFirst: return "clock.arrow.circlepath"
        case .oldestFirst: return "clock"
        }
    }
}

enum FileBrowserSortPolicy {
    static func sorted<Record>(
        _ records: [Record],
        order: FileBrowserSortOrder,
        name: KeyPath<Record, String>,
        isDirectory: KeyPath<Record, Bool>,
        size: KeyPath<Record, Int64>,
        modifiedAt: KeyPath<Record, Date?>
    ) -> [Record] {
        records.sorted { left, right in
            let leftIsDirectory = left[keyPath: isDirectory]
            let rightIsDirectory = right[keyPath: isDirectory]
            if leftIsDirectory != rightIsDirectory {
                return leftIsDirectory
            }

            let leftName = left[keyPath: name]
            let rightName = right[keyPath: name]
            let nameOrder = leftName.localizedCaseInsensitiveCompare(rightName)

            switch order {
            case .nameAscending:
                return nameOrder == .orderedAscending
            case .nameDescending:
                return nameOrder == .orderedDescending
            case .sizeDescending, .sizeAscending:
                let leftSize = left[keyPath: size]
                let rightSize = right[keyPath: size]
                let leftKnown = leftSize >= 0
                let rightKnown = rightSize >= 0
                if leftKnown != rightKnown { return leftKnown }
                if leftSize != rightSize {
                    return order == .sizeDescending
                        ? leftSize > rightSize
                        : leftSize < rightSize
                }
            case .newestFirst, .oldestFirst:
                let leftDate = left[keyPath: modifiedAt]
                let rightDate = right[keyPath: modifiedAt]
                if leftDate == nil, rightDate != nil { return false }
                if leftDate != nil, rightDate == nil { return true }
                if let leftDate, let rightDate, leftDate != rightDate {
                    return order == .newestFirst
                        ? leftDate > rightDate
                        : leftDate < rightDate
                }
            }

            return nameOrder == .orderedAscending
        }
    }
}

struct FileBrowserDirectorySummary: Equatable {
    let byteCount: Int64
    let childCount: Int
}

enum FileBrowserMetadataScanner {
    static func directorySummary(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws -> FileBrowserDirectorySummary {
        let rootValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let childCount = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).count
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var byteCount: Int64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let itemSize = Int64(max(0, values.fileSize ?? 0))
            let (sum, overflow) = byteCount.addingReportingOverflow(itemSize)
            byteCount = overflow ? Int64.max : sum
        }

        return FileBrowserDirectorySummary(
            byteCount: byteCount,
            childCount: childCount
        )
    }
}
