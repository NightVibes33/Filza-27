import Foundation
import Darwin

struct WallpaperAccessReport: Equatable {
    let layout: WallpaperPosterLayout
    let descriptorCount: Int
    let canInstall: Bool
    let deniedExtensionIdentifiers: [String]
}

enum WallpaperAccessProbe {
    static func probe(
        containerURL: URL,
        rootValidator: WallpaperLayoutScanner.RootValidator,
        requiredExtensionIdentifiers: Set<String>? = nil,
        fileManager: FileManager = .default
    ) throws -> WallpaperAccessReport {
        let layout = try WallpaperLayoutScanner.scan(
            containerURL: containerURL,
            rootValidator: rootValidator,
            fileManager: fileManager
        )
        var descriptorCount = 0
        for descriptorDirectory in layout.extensionDescriptorDirectories.values {
            let names = (try? fileManager.contentsOfDirectory(atPath: descriptorDirectory.path)) ?? []
            descriptorCount += names.filter { !$0.hasPrefix(".") }.count
        }

        let requiredIdentifiers: [String]
        if let requiredExtensionIdentifiers {
            requiredIdentifiers = requiredExtensionIdentifiers.sorted()
        } else if layout.supportsCollections {
            requiredIdentifiers = [WallpaperPosterLayout.collectionsExtension]
        } else {
            requiredIdentifiers = layout.extensionDescriptorDirectories.keys.sorted()
        }
        var deniedIdentifiers = requiredIdentifiers.filter {
            layout.extensionDescriptorDirectories[$0] == nil
        }

        for identifier in requiredIdentifiers where !deniedIdentifiers.contains(identifier) {
            guard let descriptorDirectory = layout.extensionDescriptorDirectories[identifier] else {
                continue
            }

            let probeURL = descriptorDirectory.appendingPathComponent(
                ".3105-wallpaper-probe-\(UUID().uuidString)",
                isDirectory: true
            )
            let created = mkdir(probeURL.path, 0o700) == 0
            if created {
                let descriptor = open(
                    probeURL.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                if descriptor >= 0 { close(descriptor) }
                if rmdir(probeURL.path) != 0 || descriptor < 0 {
                    deniedIdentifiers.append(identifier)
                    try? fileManager.removeItem(at: probeURL)
                }
            } else {
                deniedIdentifiers.append(identifier)
            }
        }

        return WallpaperAccessReport(
            layout: layout,
            descriptorCount: descriptorCount,
            canInstall: !requiredIdentifiers.isEmpty
                && deniedIdentifiers.isEmpty,
            deniedExtensionIdentifiers: deniedIdentifiers
        )
    }
}

struct WallpaperStagedPackage: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let packageDirectoryURL: URL
    let archiveURL: URL
    let extractedURL: URL
    let payload: TendiesPayload
    let importedAt: Date
}

enum WallpaperPackageStore {
    private static let archiveName = "wallpaper.tendies"
    private static let extractedName = "Extracted"
    private static let metadataName = "metadata.plist"

    static func stagingRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Packages", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func backupRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Backups", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func importPackage(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> WallpaperStagedPackage {
        guard sourceURL.pathExtension.lowercased() == "tendies" else {
            throw WallpaperLabError.unsupportedPackage
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw WallpaperLabError.symbolicLinkUnsupported
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= WallpaperLabLimits.maximumArchiveBytes else {
            throw WallpaperLabError.packageTooLarge
        }

        let root = try stagingRoot(fileManager: fileManager)
        let id = UUID()
        let importingURL = root.appendingPathComponent(
            ".importing-\(id.uuidString)",
            isDirectory: true
        )
        let finalURL = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: importingURL,
                withIntermediateDirectories: false
            )
            let archiveURL = importingURL.appendingPathComponent(archiveName)
            try fileManager.copyItem(at: sourceURL, to: archiveURL)
            let extractedURL = importingURL.appendingPathComponent(
                extractedName,
                isDirectory: true
            )
            _ = try SecureZIPArchive.extract(
                archiveURL: archiveURL,
                destinationURL: extractedURL,
                fileManager: fileManager
            )
            _ = try TendiesPackageInspector.inspectExtractedPackage(
                at: extractedURL,
                fileManager: fileManager
            )
            let metadata = PackageMetadata(
                id: id,
                displayName: sourceURL.deletingPathExtension().lastPathComponent,
                importedAt: Date()
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(metadata).write(
                to: importingURL.appendingPathComponent(metadataName),
                options: .atomic
            )
            guard rename(importingURL.path, finalURL.path) == 0 else {
                throw WallpaperLabError.unsafeArchive
            }
            return try loadPackage(at: finalURL, fileManager: fileManager)
        } catch let error as WallpaperLabError {
            try? fileManager.removeItem(at: importingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: importingURL)
            throw WallpaperLabError.unsupportedPackage
        }
    }

    static func packages(fileManager: FileManager = .default) -> [WallpaperStagedPackage] {
        guard let root = try? stagingRoot(fileManager: fileManager),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            return try? loadPackage(at: directory, fileManager: fileManager)
        }.sorted { $0.importedAt > $1.importedAt }
    }

    static func delete(
        _ package: WallpaperStagedPackage,
        fileManager: FileManager = .default
    ) throws {
        let root = try stagingRoot(fileManager: fileManager)
        guard package.packageDirectoryURL.deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL,
              package.packageDirectoryURL.lastPathComponent == package.id.uuidString else {
            throw WallpaperLabError.unsafeArchive
        }
        try WallpaperLayoutScanner.validateDirectory(
            package.packageDirectoryURL,
            fileManager: fileManager
        )
        try fileManager.removeItem(at: package.packageDirectoryURL)
    }

    private static func loadPackage(
        at directory: URL,
        fileManager: FileManager
    ) throws -> WallpaperStagedPackage {
        try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
        let metadataData = try Data(contentsOf: directory.appendingPathComponent(metadataName))
        let metadata = try PropertyListDecoder().decode(PackageMetadata.self, from: metadataData)
        guard directory.lastPathComponent == metadata.id.uuidString,
              !metadata.displayName.isEmpty,
              metadata.displayName.utf8.count <= 255 else {
            throw WallpaperLabError.unsupportedPackage
        }
        let archiveURL = directory.appendingPathComponent(archiveName)
        let extractedURL = directory.appendingPathComponent(extractedName, isDirectory: true)
        let payload = try TendiesPackageInspector.inspectExtractedPackage(
            at: extractedURL,
            fileManager: fileManager
        )
        return WallpaperStagedPackage(
            id: metadata.id,
            displayName: metadata.displayName,
            packageDirectoryURL: directory,
            archiveURL: archiveURL,
            extractedURL: extractedURL,
            payload: payload,
            importedAt: metadata.importedAt
        )
    }

    private static func applicationSupportURL(fileManager: FileManager) throws -> URL {
        guard let url = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WallpaperLabError.accessDenied
        }
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    private static func createApprovedDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            try WallpaperLayoutScanner.validateDirectory(url, fileManager: fileManager)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

private struct PackageMetadata: Codable {
    let id: UUID
    let displayName: String
    let importedAt: Date
}
