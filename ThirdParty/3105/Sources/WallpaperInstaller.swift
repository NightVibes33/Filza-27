import Foundation
import Darwin

struct WallpaperInstalledDescriptor: Codable, Equatable, Identifiable {
    let extensionIdentifier: String
    let directoryName: String
    let byteCount: Int64

    var id: String { "\(extensionIdentifier):\(directoryName)" }
}

enum WallpaperInstallStatus: String, Codable {
    case preparing
    case installed
    case rolledBack
    case restored
}

struct WallpaperInstallReceipt: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let generation: String
    let originalDescriptorNames: [String: [String]]
    var installedDescriptors: [WallpaperInstalledDescriptor]
    var status: WallpaperInstallStatus
    let backupDirectoryURL: URL

    var journalURL: URL {
        backupDirectoryURL.appendingPathComponent("receipt.plist")
    }
}

enum WallpaperInstaller {
    typealias RootValidator = WallpaperLayoutScanner.RootValidator

    static func install(
        payload: TendiesPayload,
        layout: WallpaperPosterLayout,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) throws -> WallpaperInstallReceipt {
        guard !payload.descriptors.isEmpty,
              payload.descriptors.count <= WallpaperLabLimits.maximumDescriptorCount,
              Int(layout.generation) != nil else {
            throw WallpaperLabError.unsupportedPackage
        }
        try prepareBackupRoot(backupRoot, fileManager: fileManager)

        var originalNames: [String: [String]] = [:]
        for (identifier, descriptorDirectory) in layout.extensionDescriptorDirectories {
            try WallpaperLayoutScanner.validateDirectory(
                descriptorDirectory,
                fileManager: fileManager
            )
            originalNames[identifier] = try fileManager.contentsOfDirectory(
                atPath: descriptorDirectory.path
            ).filter { !$0.hasPrefix(".3105-wallpaper-") }.sorted()
        }

        let transactionID = UUID()
        let transactionDirectory = backupRoot.appendingPathComponent(
            transactionID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: false
        )
        var receipt = WallpaperInstallReceipt(
            id: transactionID,
            createdAt: Date(),
            generation: layout.generation,
            originalDescriptorNames: originalNames,
            installedDescriptors: [],
            status: .preparing,
            backupDirectoryURL: transactionDirectory
        )
        try writeReceipt(receipt)

        let orderedSources = payload.descriptors.filter(\.isOrdered)
        var orderedIdentifiers: [String: Int] = [:]
        if !orderedSources.isEmpty {
            let maximumBase = 2_000_000_000 - orderedSources.count
            let base = Int.random(in: 10_000...maximumBase)
            for (index, source) in orderedSources.enumerated() {
                orderedIdentifiers[source.id] = base + orderedSources.count - index
            }
        }

        do {
            for source in payload.descriptors {
                guard let destinationDirectory = layout.extensionDescriptorDirectories[
                    source.extensionIdentifier
                ] else {
                    throw WallpaperLabError.unsupportedPosterLayout
                }
                try validateDescriptorTree(
                    source.directoryURL,
                    expectedBytes: source.byteCount,
                    expectedFiles: source.fileCount,
                    fileManager: fileManager
                )

                let directoryName = UUID().uuidString.uppercased()
                guard !(originalNames[source.extensionIdentifier] ?? []).contains(directoryName) else {
                    throw WallpaperLabError.installFailed
                }
                let installedDescriptor = WallpaperInstalledDescriptor(
                    extensionIdentifier: source.extensionIdentifier,
                    directoryName: directoryName,
                    byteCount: source.byteCount
                )
                receipt.installedDescriptors.append(installedDescriptor)
                try writeReceipt(receipt)

                let stagingURL = destinationDirectory.appendingPathComponent(
                    ".3105-wallpaper-\(UUID().uuidString)",
                    isDirectory: true
                )
                let finalURL = destinationDirectory.appendingPathComponent(
                    directoryName,
                    isDirectory: true
                )
                defer { try? fileManager.removeItem(at: stagingURL) }
                try fileManager.copyItem(at: source.directoryURL, to: stagingURL)
                try validateDescriptorTree(
                    stagingURL,
                    expectedBytes: source.byteCount,
                    expectedFiles: source.fileCount,
                    fileManager: fileManager
                )
                try WallpaperDescriptorRewriter.randomize(
                    in: stagingURL,
                    identifier: orderedIdentifiers[source.id],
                    fileManager: fileManager
                )
                guard rename(stagingURL.path, finalURL.path) == 0 else {
                    throw WallpaperLabError.installFailed
                }
                try synchronizeDirectory(destinationDirectory)
            }

            receipt.status = .installed
            try writeReceipt(receipt)
            return receipt
        } catch {
            rollbackInstalledDescriptors(
                receipt.installedDescriptors,
                layout: layout,
                fileManager: fileManager
            )
            receipt.status = .rolledBack
            try? writeReceipt(receipt)
            if let wallpaperError = error as? WallpaperLabError {
                throw wallpaperError
            }
            throw WallpaperLabError.installFailed
        }
    }

    static func restore(
        receipt rawReceipt: WallpaperInstallReceipt,
        containerURL rawContainerURL: URL,
        rootValidator: RootValidator,
        fileManager: FileManager = .default
    ) throws {
        let containerURL = rawContainerURL.standardizedFileURL
        guard containerURL.isFileURL,
              containerURL.path != "/",
              rootValidator(containerURL),
              Int(rawReceipt.generation) != nil else {
            throw WallpaperLabError.unsafeContainerRoot
        }
        try WallpaperLayoutScanner.validateDirectory(containerURL, fileManager: fileManager)
        try WallpaperLayoutScanner.validatePathComponents(
            relativePath: WallpaperLayoutScanner.storeRelativePath,
            root: containerURL,
            fileManager: fileManager
        )

        var receipt = rawReceipt
        do {
            for installed in receipt.installedDescriptors {
                guard WallpaperLayoutScanner.validExtensionIdentifier(
                    installed.extensionIdentifier
                ), UUID(uuidString: installed.directoryName) != nil else {
                    throw WallpaperLabError.restoreFailed
                }
                guard !(receipt.originalDescriptorNames[installed.extensionIdentifier] ?? [])
                    .contains(installed.directoryName) else {
                    throw WallpaperLabError.restoreFailed
                }

                let descriptorsURL = containerURL
                    .appendingPathComponent(WallpaperLayoutScanner.storeRelativePath, isDirectory: true)
                    .appendingPathComponent(receipt.generation, isDirectory: true)
                    .appendingPathComponent("Extensions", isDirectory: true)
                    .appendingPathComponent(installed.extensionIdentifier, isDirectory: true)
                    .appendingPathComponent("descriptors", isDirectory: true)
                guard WallpaperLayoutScanner.isContained(descriptorsURL, in: containerURL) else {
                    throw WallpaperLabError.restoreFailed
                }
                try WallpaperLayoutScanner.validateDirectory(
                    descriptorsURL,
                    fileManager: fileManager
                )
                let installedURL = descriptorsURL.appendingPathComponent(
                    installed.directoryName,
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: installedURL.path) {
                    try WallpaperLayoutScanner.validateDirectory(
                        installedURL,
                        fileManager: fileManager
                    )
                    try fileManager.removeItem(at: installedURL)
                    try synchronizeDirectory(descriptorsURL)
                }
            }
            receipt.status = .restored
            try writeReceipt(receipt)
        } catch let error as WallpaperLabError {
            throw error
        } catch {
            throw WallpaperLabError.restoreFailed
        }
    }

    static func receipts(
        in backupRoot: URL,
        fileManager: FileManager = .default
    ) -> [WallpaperInstallReceipt] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let values = try? directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(
                    contentsOf: directory.appendingPathComponent("receipt.plist")
                  ),
                  let receipt = try? PropertyListDecoder().decode(
                    WallpaperInstallReceipt.self,
                    from: data
                  ),
                  receipt.backupDirectoryURL.standardizedFileURL
                    == directory.standardizedFileURL else {
                return nil
            }
            return receipt
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func removeReceipt(
        _ receipt: WallpaperInstallReceipt,
        from backupRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = backupRoot.standardizedFileURL
        let directory = receipt.backupDirectoryURL.standardizedFileURL
        guard root.isFileURL,
              root.path != "/",
              directory.deletingLastPathComponent() == root,
              directory.lastPathComponent == receipt.id.uuidString,
              receipt.journalURL.standardizedFileURL
                == directory.appendingPathComponent("receipt.plist").standardizedFileURL else {
            throw WallpaperLabError.restoreFailed
        }

        do {
            try WallpaperLayoutScanner.validateDirectory(root, fileManager: fileManager)
            try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
            let data = try Data(contentsOf: receipt.journalURL)
            let storedReceipt = try PropertyListDecoder().decode(
                WallpaperInstallReceipt.self,
                from: data
            )
            guard storedReceipt.id == receipt.id,
                  storedReceipt.status == .restored,
                  storedReceipt.backupDirectoryURL.standardizedFileURL == directory else {
                throw WallpaperLabError.restoreFailed
            }
            try fileManager.removeItem(at: directory)
        } catch {
            throw WallpaperLabError.restoreFailed
        }
    }

    private static func prepareBackupRoot(
        _ backupRoot: URL,
        fileManager: FileManager
    ) throws {
        guard backupRoot.isFileURL,
              backupRoot.standardizedFileURL.path.hasPrefix("/"),
              backupRoot.standardizedFileURL.path != "/" else {
            throw WallpaperLabError.backupFailed
        }
        if fileManager.fileExists(atPath: backupRoot.path) {
            do {
                try WallpaperLayoutScanner.validateDirectory(
                    backupRoot,
                    fileManager: fileManager
                )
            } catch {
                throw WallpaperLabError.backupFailed
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: backupRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                throw WallpaperLabError.backupFailed
            }
        }
    }

    private static func validateDescriptorTree(
        _ root: URL,
        expectedBytes: Int64,
        expectedFiles: Int,
        fileManager: FileManager
    ) throws {
        try WallpaperLayoutScanner.validateDirectory(root, fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw WallpaperLabError.unsupportedPackage }
        var bytes: Int64 = 0
        var files = 0
        for case let itemURL as URL in enumerator {
            guard WallpaperLayoutScanner.isContained(itemURL, in: root) else {
                throw WallpaperLabError.unsafeArchive
            }
            let values = try itemURL.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true else {
                throw WallpaperLabError.symbolicLinkUnsupported
            }
            if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                files += 1
            } else if values.isDirectory != true {
                throw WallpaperLabError.unsupportedPackage
            }
            guard bytes <= WallpaperLabLimits.maximumExpandedBytes,
                  files <= WallpaperLabLimits.maximumEntryCount else {
                throw WallpaperLabError.packageTooLarge
            }
        }
        guard bytes == expectedBytes, files == expectedFiles else {
            throw WallpaperLabError.unsafeArchive
        }
    }

    private static func rollbackInstalledDescriptors(
        _ installedDescriptors: [WallpaperInstalledDescriptor],
        layout: WallpaperPosterLayout,
        fileManager: FileManager
    ) {
        for installed in installedDescriptors {
            guard let descriptorsURL = layout.extensionDescriptorDirectories[
                installed.extensionIdentifier
            ], UUID(uuidString: installed.directoryName) != nil else { continue }
            let url = descriptorsURL.appendingPathComponent(
                installed.directoryName,
                isDirectory: true
            )
            guard WallpaperLayoutScanner.isContained(url, in: descriptorsURL) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func writeReceipt(_ receipt: WallpaperInstallReceipt) throws {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(receipt).write(to: receipt.journalURL, options: .atomic)
        } catch {
            throw WallpaperLabError.backupFailed
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WallpaperLabError.installFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL else {
            throw WallpaperLabError.installFailed
        }
    }
}

enum WallpaperDescriptorRewriter {
    static func randomize(
        in descriptorURL: URL,
        identifier suppliedIdentifier: Int? = nil,
        fileManager: FileManager = .default
    ) throws {
        let identifier = suppliedIdentifier ?? Int.random(in: 10_000...2_000_000_000)
        guard let enumerator = fileManager.enumerator(
            at: descriptorURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw WallpaperLabError.unsupportedPackage }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw WallpaperLabError.symbolicLinkUnsupported
            }
            guard values.isRegularFile == true else { continue }

            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                guard let data = String(identifier).data(using: .utf8) else {
                    throw WallpaperLabError.unsupportedPackage
                }
                try data.write(to: fileURL, options: .atomic)
            case "com.apple.posterkit.provider.contents.userInfo":
                try updatePropertyList(
                    at: fileURL,
                    key: "wallpaperRepresentingIdentifier",
                    value: identifier
                )
            case "Wallpaper.plist":
                try updatePropertyList(at: fileURL, key: "identifier", value: identifier)
            default:
                continue
            }
        }
    }

    private static func updatePropertyList(
        at url: URL,
        key: String,
        value: Int
    ) throws {
        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let data = try Data(contentsOf: url)
            guard var propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] else {
                throw WallpaperLabError.unsupportedPackage
            }
            propertyList[key] = value
            let updated = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: format,
                options: 0
            )
            try updated.write(to: url, options: .atomic)
        } catch let error as WallpaperLabError {
            throw error
        } catch {
            throw WallpaperLabError.unsupportedPackage
        }
    }
}
