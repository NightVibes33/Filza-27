import CryptoKit
import Darwin
import Foundation

struct PatchTransactionReceipt: Equatable, Identifiable {
    let id: UUID
    let projectID: UUID
    let journalURL: URL
}

enum PatchTargetChangeKind: Equatable {
    case modified
    case missing
}

struct PatchTargetChange: Equatable {
    let bundleID: String
    let relativePath: String
    let kind: PatchTargetChangeKind

    var displayPath: String {
        bundleID + "/" + relativePath
    }
}

struct PatchRestoreInspection: Equatable {
    let changedTargets: [PatchTargetChange]
}

enum PatchTransaction {
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let originalExisted: Bool
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
        let appliedFilename: String?
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        let createdDirectories: [DirectoryRecord]?
    }

    private struct ResolvedRule {
        let rule: PatchRule
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedDirectory {
        let bundleID: String
        let relativePath: String
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedRecord {
        let record: Record
        let target: URL
    }

    private struct CurrentFileSnapshot {
        let target: URL
        let existed: Bool
        let snapshotURL: URL?
    }

    private enum AppliedSource {
        case file(URL)
        case data(Data)
    }

    private static let minimumSchemaVersion = 1
    private static let schemaVersion = 2
    private static let journalFilename = "journal.plist"

    static func apply(
        project: PatchProject,
        backupRoot: URL,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> PatchTransactionReceipt {
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        guard latestReceipt(
            projectID: project.id,
            backupRoot: backupRoot,
            fileManager: fileManager
        ) == nil else {
            throw PatchPackageError.projectAlreadyApplied
        }

        var roots: [String: URL] = [:]
        var resolvedRules: [ResolvedRule] = []
        var resolvedDirectories: [ResolvedDirectory] = []
        var targetKeys = Set<String>()

        func resolvedRoot(for bundleID: String) throws -> URL {
            if let cached = roots[bundleID] { return cached }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            roots[bundleID] = root
            return root
        }

        var requestedDirectories = Set<String>()
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            guard bundleID == directory.bundleID else { throw PatchPackageError.invalidProject }
            requestedDirectories.insert(bundleID + "\0" + directory.relativePath)
        }
        for rule in project.rules {
            let components = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
                .split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requestedDirectories.insert(
                    rule.bundleID + "\0" + components.prefix(count).joined(separator: "/")
                )
            }
        }

        for key in requestedDirectories.sorted(by: directoryKeySort) {
            let parts = key.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PatchPackageError.invalidProject }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(String(parts[0]))
            let relativePath = try PatchPathValidator.canonicalRelativePath(String(parts[1]))
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: root
            )
            try validateDirectoryTarget(
                target,
                relativePath: relativePath,
                containerRoot: root,
                fileManager: fileManager
            )
            resolvedDirectories.append(ResolvedDirectory(
                bundleID: bundleID,
                relativePath: relativePath,
                containerRoot: root,
                target: target
            ))
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            guard bundleID == rule.bundleID else { throw PatchPackageError.invalidProject }
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: rule.relativePath,
                containerRoot: root
            )
            let targetKey = target.path
            guard targetKeys.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            try validateFileTarget(
                target,
                relativePath: rule.relativePath,
                containerRoot: root,
                allowMissingParents: true,
                fileManager: fileManager
            )
            resolvedRules.append(ResolvedRule(rule: rule, containerRoot: root, target: target))
        }

        let occupied = appliedTargetKeys(
            backupRoot: backupRoot,
            excludingProjectID: project.id,
            fileManager: fileManager
        )
        for resolved in resolvedRules {
            let occupancyKey = resolved.rule.bundleID + "\0" + resolved.rule.relativePath
            if occupied.contains(occupancyKey) {
                throw PatchPackageError.targetOccupied(
                    resolved.rule.bundleID + "/" + resolved.rule.relativePath
                )
            }
        }

        let transactionID = UUID()
        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        } catch {
            throw PatchPackageError.applyFailed
        }

        var records: [Record] = []
        let createdDirectories = resolvedDirectories.compactMap { resolved -> DirectoryRecord? in
            guard !fileManager.fileExists(atPath: resolved.target.path) else { return nil }
            return DirectoryRecord(
                bundleID: resolved.bundleID,
                relativePath: resolved.relativePath,
                containerFingerprint: containerFingerprint(resolved.containerRoot)
            )
        }
        do {
            for resolved in resolvedRules {
                let existed = fileManager.fileExists(atPath: resolved.target.path)
                let backupFilename = existed ? "\(resolved.rule.id.uuidString).original" : nil
                let appliedFilename = project.isPrivate
                    ? nil
                    : "\(resolved.rule.id.uuidString).applied"
                var originalDigest: Data?
                if let backupFilename {
                    let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                    try fileManager.copyItem(at: resolved.target, to: backupURL)
                    originalDigest = try digestFile(backupURL)
                }
                let replacementDigest = digest(resolved.rule.replacementData)
                if let appliedFilename {
                    let appliedURL = transactionDirectory.appendingPathComponent(appliedFilename)
                    try resolved.rule.replacementData.write(to: appliedURL, options: .atomic)
                    guard try digestFile(appliedURL) == replacementDigest else {
                        throw PatchPackageError.applyFailed
                    }
                }
                records.append(Record(
                    ruleID: resolved.rule.id,
                    bundleID: resolved.rule.bundleID,
                    relativePath: resolved.rule.relativePath,
                    containerFingerprint: containerFingerprint(resolved.containerRoot),
                    originalExisted: existed,
                    backupFilename: backupFilename,
                    originalDigest: originalDigest,
                    replacementDigest: replacementDigest,
                    appliedFilename: appliedFilename
                ))
            }
        } catch let error as PatchPackageError {
            throw error
        } catch {
            throw PatchPackageError.applyFailed
        }

        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        var journal = Journal(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: createdDirectories
        )
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            throw PatchPackageError.applyFailed
        }

        do {
            for resolved in resolvedDirectories where !fileManager.fileExists(atPath: resolved.target.path) {
                try fileManager.createDirectory(
                    at: resolved.target,
                    withIntermediateDirectories: false
                )
            }
            for (index, resolved) in resolvedRules.enumerated() {
                try beforeWrite?(index)
                try atomicWrite(
                    resolved.rule.replacementData,
                    to: resolved.target,
                    preservingExistingAttributes: true,
                    fileManager: fileManager
                )
                guard try digestFile(resolved.target) == records[index].replacementDigest else {
                    throw PatchPackageError.applyFailed
                }
            }
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL
            )
        } catch {
            do {
                try restoreRecords(
                    records,
                    transactionDirectory: transactionDirectory,
                    roots: roots,
                    requirePatchedDigest: false,
                    createdDirectories: createdDirectories,
                    fileManager: fileManager
                )
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
            } catch {
                // Preserve the prepared journal and backups for explicit recovery.
            }
            throw PatchPackageError.applyFailed
        }
    }

    static func inspectRestore(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws -> PatchRestoreInspection {
        do {
            let journal = try activeJournal(for: receipt)
            guard journal.status == .applied else {
                return PatchRestoreInspection(changedTargets: [])
            }
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            let resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                roots: roots,
                fileManager: fileManager
            )
            return PatchRestoreInspection(
                changedTargets: try changedTargets(in: resolved, fileManager: fileManager)
            )
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws {
        do {
            var journal = try activeJournal(for: receipt)
            let transactionDirectory = receipt.journalURL.deletingLastPathComponent()
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            let resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: transactionDirectory,
                roots: roots,
                allowMissingParents: journal.status == .prepared,
                fileManager: fileManager
            )
            let changes = journal.status == .applied
                ? try changedTargets(in: resolved, fileManager: fileManager)
                : []
            if !changes.isEmpty, !allowChangedTargets {
                throw PatchPackageError.restoreTargetsChanged(changes.map(\.displayPath))
            }
            let createdDirectoryURLs = try resolvedCreatedDirectories(
                journal.createdDirectories ?? [],
                roots: roots,
                fileManager: fileManager
            )

            try withCurrentStateRecovery(
                resolved,
                transactionDirectory: transactionDirectory,
                fileManager: fileManager
            ) {
                for (index, item) in resolved.reversed().enumerated() {
                    try beforeWrite?(index)
                    if item.record.originalExisted {
                        let backup = transactionDirectory.appendingPathComponent(
                            item.record.backupFilename!
                        )
                        try atomicCopy(backup, to: item.target, fileManager: fileManager)
                    } else if fileManager.fileExists(atPath: item.target.path) {
                        try fileManager.removeItem(at: item.target)
                    }
                }
                journal.status = .restored
                try writeJournal(journal, to: receipt.journalURL)
            }

            removeEmptyCreatedDirectories(createdDirectoryURLs, fileManager: fileManager)
        } catch let error as PatchPackageError {
            if case .restoreTargetsChanged = error { throw error }
            throw PatchPackageError.restoreFailed
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        fallbackProject: PatchProject? = nil,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws {
        do {
            let journal = try activeJournal(for: receipt)
            guard journal.status == .applied else {
                throw PatchPackageError.resetFailed
            }
            let transactionDirectory = receipt.journalURL.deletingLastPathComponent()
            let roots = try resolvedRoots(
                journal: journal,
                containerResolver: containerResolver
            )
            let resolved = try resolvedRecords(
                journal.records,
                transactionDirectory: transactionDirectory,
                roots: roots,
                fileManager: fileManager
            )
            let fallbackRules = Dictionary(
                uniqueKeysWithValues: (fallbackProject?.rules ?? []).map { ($0.id, $0) }
            )
            let sources = try resolved.map { item -> AppliedSource in
                if let filename = item.record.appliedFilename {
                    let source = transactionDirectory.appendingPathComponent(filename)
                    guard fileManager.fileExists(atPath: source.path),
                          try digestFile(source) == item.record.replacementDigest else {
                        throw PatchPackageError.resetFailed
                    }
                    return .file(source)
                }
                guard let rule = fallbackRules[item.record.ruleID],
                      rule.bundleID == item.record.bundleID,
                      rule.relativePath == item.record.relativePath,
                      digest(rule.replacementData) == item.record.replacementDigest else {
                    throw PatchPackageError.resetFailed
                }
                return .data(rule.replacementData)
            }

            try withCurrentStateRecovery(
                resolved,
                transactionDirectory: transactionDirectory,
                fileManager: fileManager
            ) {
                for (index, item) in resolved.enumerated() {
                    try beforeWrite?(index)
                    switch sources[index] {
                    case .file(let source):
                        try atomicCopy(
                            source,
                            to: item.target,
                            preservingExistingAttributes: true,
                            fileManager: fileManager
                        )
                    case .data(let data):
                        try atomicWrite(
                            data,
                            to: item.target,
                            preservingExistingAttributes: true,
                            fileManager: fileManager
                        )
                    }
                    guard try digestFile(item.target) == item.record.replacementDigest else {
                        throw PatchPackageError.resetFailed
                    }
                }
            }
        } catch {
            throw PatchPackageError.resetFailed
        }
    }

    static func latestReceipt(
        projectID: UUID,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url),
                  (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
                  journal.status == .applied || journal.status == .prepared else { return nil }
            return (journal, url)
        }
        .sorted { $0.0.createdAt > $1.0.createdAt }
        .first
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1
            )
        }
    }

    static func appliedTargetKeys(
        backupRoot: URL,
        excludingProjectID: UUID? = nil,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var keys = Set<String>()
        for directory in projectDirectories {
            guard let projectID = UUID(uuidString: directory.lastPathComponent),
                  projectID != excludingProjectID,
                  let receipt = latestReceipt(
                    projectID: projectID,
                    backupRoot: backupRoot,
                    fileManager: fileManager
                  ),
                  let journal = try? readJournal(receipt.journalURL),
                  journal.status == .applied || journal.status == .prepared
            else { continue }
            for record in journal.records {
                keys.insert(record.bundleID + "\0" + record.relativePath)
            }
        }
        return keys
    }

    static func requiredBundleIdentifiers(for receipt: PatchTransactionReceipt) throws -> [String] {
        let journal = try readJournal(receipt.journalURL)
        guard (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID else {
            throw PatchPackageError.restoreFailed
        }
        var seen = Set<String>()
        return (journal.records.map(\.bundleID)
            + (journal.createdDirectories ?? []).map(\.bundleID)).compactMap { bundleID in
                seen.insert(bundleID).inserted ? bundleID : nil
            }
    }

    private static func activeJournal(for receipt: PatchTransactionReceipt) throws -> Journal {
        let journal = try readJournal(receipt.journalURL)
        guard (minimumSchemaVersion...schemaVersion).contains(journal.schemaVersion),
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared else {
            throw PatchPackageError.restoreFailed
        }
        return journal
    }

    private static func resolvedRoots(
        journal: Journal,
        containerResolver: (String) throws -> URL
    ) throws -> [String: URL] {
        var roots: [String: URL] = [:]
        let identities = journal.records.map { ($0.bundleID, $0.containerFingerprint) }
            + (journal.createdDirectories ?? []).map { ($0.bundleID, $0.containerFingerprint) }
        for (bundleID, expectedFingerprint) in identities {
            if let root = roots[bundleID] {
                guard containerFingerprint(root) == expectedFingerprint else {
                    throw PatchPackageError.restoreFailed
                }
                continue
            }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            guard containerFingerprint(root) == expectedFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            roots[bundleID] = root
        }
        return roots
    }

    private static func resolvedRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        allowMissingParents: Bool = false,
        fileManager: FileManager
    ) throws -> [ResolvedRecord] {
        try records.map { record in
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            try validateFileTarget(
                target,
                relativePath: record.relativePath,
                containerRoot: root,
                allowMissingParents: allowMissingParents,
                fileManager: fileManager
            )
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            return ResolvedRecord(record: record, target: target)
        }
    }

    private static func changedTargets(
        in resolved: [ResolvedRecord],
        fileManager: FileManager
    ) throws -> [PatchTargetChange] {
        try resolved.compactMap { item in
            guard fileManager.fileExists(atPath: item.target.path) else {
                return PatchTargetChange(
                    bundleID: item.record.bundleID,
                    relativePath: item.record.relativePath,
                    kind: .missing
                )
            }
            guard try digestFile(item.target) != item.record.replacementDigest else {
                return nil
            }
            return PatchTargetChange(
                bundleID: item.record.bundleID,
                relativePath: item.record.relativePath,
                kind: .modified
            )
        }
    }

    private static func resolvedCreatedDirectories(
        _ directories: [DirectoryRecord],
        roots: [String: URL],
        fileManager: FileManager
    ) throws -> [URL] {
        try directories.map { directory in
            guard let root = roots[directory.bundleID],
                  containerFingerprint(root) == directory.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: directory.relativePath,
                containerRoot: root
            )
            if fileManager.fileExists(atPath: target.path) {
                let values = try target.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw PatchPackageError.restoreFailed
                }
            }
            return target
        }
    }

    private static func withCurrentStateRecovery(
        _ resolved: [ResolvedRecord],
        transactionDirectory: URL,
        fileManager: FileManager,
        operation: () throws -> Void
    ) throws {
        let recoveryDirectory = transactionDirectory.appendingPathComponent(
            ".recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false)
        var snapshots: [CurrentFileSnapshot] = []
        do {
            for (index, item) in resolved.enumerated() {
                guard fileManager.fileExists(atPath: item.target.path) else {
                    snapshots.append(CurrentFileSnapshot(
                        target: item.target,
                        existed: false,
                        snapshotURL: nil
                    ))
                    continue
                }
                let snapshotURL = recoveryDirectory.appendingPathComponent("\(index).current")
                try fileManager.copyItem(at: item.target, to: snapshotURL)
                guard try digestFile(snapshotURL) == digestFile(item.target) else {
                    throw PatchPackageError.restoreFailed
                }
                snapshots.append(CurrentFileSnapshot(
                    target: item.target,
                    existed: true,
                    snapshotURL: snapshotURL
                ))
            }
        } catch {
            try? fileManager.removeItem(at: recoveryDirectory)
            throw error
        }

        do {
            try operation()
        } catch {
            do {
                for snapshot in snapshots.reversed() {
                    if snapshot.existed, let snapshotURL = snapshot.snapshotURL {
                        try atomicCopy(snapshotURL, to: snapshot.target, fileManager: fileManager)
                    } else if fileManager.fileExists(atPath: snapshot.target.path) {
                        try fileManager.removeItem(at: snapshot.target)
                    }
                }
                try? fileManager.removeItem(at: recoveryDirectory)
            } catch {
                // Keep the recovery directory when rollback cannot complete.
                throw PatchPackageError.restoreFailed
            }
            throw error
        }
        try? fileManager.removeItem(at: recoveryDirectory)
    }

    private static func removeEmptyCreatedDirectories(
        _ directories: [URL],
        fileManager: FileManager
    ) {
        for directory in directories.reversed() {
            guard fileManager.fileExists(atPath: directory.path),
                  let values = try? directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isSymbolicLink != true,
                  values.isDirectory == true,
                  let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func restoreRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        requirePatchedDigest: Bool,
        createdDirectories: [DirectoryRecord],
        fileManager: FileManager
    ) throws {
        var resolvedTargets: [(Record, URL)] = []
        for record in records {
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            try validateFileTarget(
                target,
                relativePath: record.relativePath,
                containerRoot: root,
                allowMissingParents: !requirePatchedDigest,
                fileManager: fileManager
            )

            if requirePatchedDigest {
                guard fileManager.fileExists(atPath: target.path),
                      try digestFile(target) == record.replacementDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            resolvedTargets.append((record, target))
        }

        for (record, target) in resolvedTargets.reversed() {
            if record.originalExisted {
                let backup = transactionDirectory.appendingPathComponent(record.backupFilename!)
                try atomicCopy(backup, to: target, fileManager: fileManager)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }

        for directory in createdDirectories.reversed() {
            guard let root = roots[directory.bundleID],
                  containerFingerprint(root) == directory.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: directory.relativePath,
                containerRoot: root
            )
            guard fileManager.fileExists(atPath: target.path) else { continue }
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.restoreFailed
            }
            let contents = try fileManager.contentsOfDirectory(atPath: target.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private static func validateFileTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        allowMissingParents: Bool,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/")
            .map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else {
                if allowMissingParents { break }
                throw PatchPackageError.applyFailed
            }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory != true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func validateDirectoryTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/").map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else { break }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func directoryKeySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func atomicWrite(
        _ data: Data,
        to target: URL,
        preservingExistingAttributes: Bool,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-patch-\(UUID().uuidString)")
        var attributes: [FileAttributeKey: Any] = [:]
        if preservingExistingAttributes,
           let current = try? fileManager.attributesOfItem(atPath: target.path) {
            if let permissions = current[.posixPermissions] { attributes[.posixPermissions] = permissions }
            if let protection = current[.protectionKey] { attributes[.protectionKey] = protection }
        }
        guard fileManager.createFile(atPath: staging.path, contents: data, attributes: attributes) else {
            throw PatchPackageError.applyFailed
        }
        defer { try? fileManager.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.applyFailed
        }
    }

    private static func atomicCopy(
        _ source: URL,
        to target: URL,
        preservingExistingAttributes: Bool = false,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-restore-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if preservingExistingAttributes,
           let current = try? fileManager.attributesOfItem(atPath: target.path) {
            var attributes: [FileAttributeKey: Any] = [:]
            if let permissions = current[.posixPermissions] {
                attributes[.posixPermissions] = permissions
            }
            if let protection = current[.protectionKey] {
                attributes[.protectionKey] = protection
            }
            if !attributes.isEmpty {
                try fileManager.setAttributes(attributes, ofItemAtPath: staging.path)
            }
        }
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.restoreFailed
        }
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func containerFingerprint(_ url: URL) -> Data {
        digest(Data(PatchPathValidator.canonicalFileURL(url).path.utf8))
    }
}
