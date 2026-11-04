import Foundation

/// Erosion-backed cache inspection for *any* installed application returned
/// by paired InstallationProxy. This is an opt-in fallback only after normal
/// 3105/MCM scanning; metadata alone never makes remote data writable.
struct FilzaRemoteCleanerEntry: Identifiable {
    let root: String
    let child: String
    let bytes: Int64
    var id: String { root + "/" + child }
    var absolutePath: String { root + "/" + child }
}

struct FilzaRemoteCleanerInventory {
    let bundleID: String
    let displayName: String
    let containerPath: String
    let entries: [FilzaRemoteCleanerEntry]
    let checkedAt: Date
    let failures: [String]
    var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var canClean: Bool { failures.isEmpty && !entries.isEmpty }
}

struct FilzaRemoteCleanerOutcome {
    let acceptedRemovals: Int
    let estimatedBytes: Int64
    let failures: [String]
}

/// This does not touch Documents, databases, Preferences, or app containers.
/// Remote removal is never automatic and stops on the first denied operation.
/// The upstream Airlift primitive only confirms a transport result; reported
/// byte counts are estimates until separately verified on the iPhone.
enum FilzaAirliftCleaner {
    enum Failure: LocalizedError {
        case unpaired
        case invalidContainer
        case incompleteRead(String)
        case unsafeCacheContents(String)
        case expiredInventory

        var errorDescription: String? {
            switch self {
            case .unpaired: return "Pair this iPhone and connect LocalDevVPN first."
            case .invalidContainer: return "Airlift did not return a valid installed-app data container."
            case .incompleteRead(let detail): return "Cache inspection incomplete: \(detail)"
            case .unsafeCacheContents(let detail): return "Unsafe cache snapshot: \(detail)"
            case .expiredInventory: return "Cache scan is stale. Scan again before cleaning."
            }
        }
    }

    private static let permitted = ["Library/Caches", "tmp"]
    private static let maximumEntriesPerRoot = 250
    private static let maximumRemoteOperations = 100

    static func checkedContainer(_ path: String) -> String? {
        let normalized = path.hasPrefix("/private/")
            ? String(path.dropFirst("/private".count)) : path
        let roots = [
            "/var/mobile/Containers/Data/Application/",
            "/var/containers/Data/Application/"
        ]
        for root in roots where normalized.hasPrefix(root) {
            let suffix = String(normalized.dropFirst(root.count))
            if UUID(uuidString: suffix) != nil { return normalized }
        }
        return nil
    }

    static func inspect(_ app: FilzaAirliftApp) async throws -> FilzaRemoteCleanerInventory {
        guard FilzaAirlift.pairedRecord() != nil else { throw Failure.unpaired }
        guard let candidate = app.dataPath,
              let root = checkedContainer(candidate) else { throw Failure.invalidContainer }

        var entries: [FilzaRemoteCleanerEntry] = []
        var errors: [String] = []

        for relative in permitted {
            let remote = root + "/" + relative
            do {
                // The shared Airlift reader rejects partial reads and
                // unconfirmed original-object restoration before returning.
                let zip = try await FilzaAirlift.snapshot(path: remote, folder: true)
                let found = try await Task.detached(priority: .utility) {
                    try inspectVerifiedZIP(zip, remote: remote)
                }.value
                entries += found
                FilzaDiagnosticsAppend(
                    "Cleaner",
                    "Airlift scan \(app.bundleID) \(relative): \(found.count) top-level cache entries"
                )
            } catch let error as FilzaAirliftError {
                if case .unsafeRecovery = error { throw error }
                errors.append("\(relative): \(error.localizedDescription)")
            } catch {
                errors.append("\(relative): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            FilzaDiagnosticsAppend(
                "Cleaner", "Airlift cache probe partial for \(app.bundleID): " + errors.joined(separator: "; ")
            )
        }
        // A failed half of the scan does not silently authorize deletion.
        return FilzaRemoteCleanerInventory(
            bundleID: app.bundleID,
            displayName: app.name,
            containerPath: root,
            entries: entries,
            checkedAt: Date(),
            failures: errors
        )
    }

    private static func inspectVerifiedZIP(
        _ zip: URL,
        remote: String
    ) throws -> [FilzaRemoteCleanerEntry] {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(
            "FilzaCleaner-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }
        _ = try SecureZIPArchive.extract(archiveURL: zip, destinationURL: staging)
        let children = try fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
            options: []
        )
        guard children.count <= maximumEntriesPerRoot else {
            throw Failure.unsafeCacheContents("Too many top-level entries for one remote operation")
        }
        var result: [FilzaRemoteCleanerEntry] = []
        for child in children {
            let name = child.lastPathComponent
            guard name != ".", name != "..", !name.isEmpty,
                  !name.contains("/"), !name.contains("\0") else {
                throw Failure.unsafeCacheContents("Invalid filename")
            }
            // Extraction already rejects ZIP symlinks. Check staged content
            // independently, and never follow a local symlink for inventory.
            let values = try child.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey
            ])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw Failure.unsafeCacheContents("Non-regular cache entry \(name)")
            }
            var bytes: Int64 = 0
            let iterator = fm.enumerator(
                at: child, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            )
            if values.isRegularFile == true {
                bytes = Int64((try child.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            } else {
                while let item = iterator?.nextObject() as? URL {
                    let props = try item.resourceValues(forKeys: [
                        .fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey
                    ])
                    guard props.isSymbolicLink != true else {
                        throw Failure.unsafeCacheContents("Symlink inside \(name)")
                    }
                    if props.isRegularFile == true { bytes += Int64(props.fileSize ?? 0) }
                }
            }
            result.append(.init(root: remote, child: name, bytes: bytes))
        }
        return result
    }

    static func removeVerifiedCacheEntries(
        _ inventory: FilzaRemoteCleanerInventory
    ) async throws -> FilzaRemoteCleanerOutcome {
        guard FilzaAirlift.pairedRecord() != nil else { throw Failure.unpaired }
        guard checkedContainer(inventory.containerPath) != nil,
              inventory.failures.isEmpty, inventory.entries.count <= maximumRemoteOperations,
              Date().timeIntervalSince(inventory.checkedAt) < 90 else {
            throw Failure.expiredInventory
        }
        var accepted = 0
        var estimated: Int64 = 0
        var errors: [String] = []
        for entry in inventory.entries {
            let allowed = permitted.contains { entry.root == inventory.containerPath + "/" + $0 }
            guard allowed, entry.child != ".", entry.child != "..",
                  !entry.child.isEmpty, !entry.child.contains("/") else {
                throw Failure.unsafeCacheContents("Unexpected deletion target")
            }
            do {
                try await FilzaAirlift.removeRemote(path: entry.absolutePath)
                accepted += 1
                estimated += entry.bytes
                FilzaDiagnosticsAppend(
                    "Cleaner", "Airlift deletion accepted \(inventory.bundleID) \(entry.root.suffix(28))/\(entry.child)"
                )
            } catch {
                errors.append("\(entry.child): \(error.localizedDescription)")
                FilzaDiagnosticsAppend("Cleaner", "Airlift deletion stopped: \(error.localizedDescription)")
                break
            }
        }
        return .init(acceptedRemovals: accepted, estimatedBytes: estimated, failures: errors)
    }
}
