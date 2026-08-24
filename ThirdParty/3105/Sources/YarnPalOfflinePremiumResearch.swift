import Foundation

@objc(FilzaYarnPalResearchBridge)
final class FilzaYarnPalResearchBridge: NSObject {
    private static let stateQueue = DispatchQueue(label: "com.nightvibes33.filza.yarnpal-research-state")
    private static var isScanning = false

    @objc static func preparePatchIfPossible() {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !isScanning else { return false }
            isScanning = true
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                stateQueue.sync { isScanning = false }
            }

            do {
                let result = try YarnPalOfflinePremiumResearch.scan()
                switch result {
                case .reportCreated(let reportURL, let inspectedFiles, let candidates):
                    log(
                        "yarnpal-research: entitlement audit saved=\(reportURL.path) " +
                        "files=\(inspectedFiles) candidates=\(candidates)"
                    )
                case .appUnavailable:
                    log("yarnpal-research: YarnPal app container is unavailable")
                }
            } catch {
                log("yarnpal-research: entitlement audit failed: \(error.localizedDescription)")
            }
        }
    }
}

enum YarnPalResearchScanResult {
    case reportCreated(reportURL: URL, inspectedFiles: Int, candidates: Int)
    case appUnavailable
}

enum YarnPalOfflinePremiumResearch {
    static let bundleIdentifier = "com.knitpal.knitcrochet"

    private static let maximumCandidateBytes = 8 * 1_024 * 1_024
    private static let maximumFilesToInspect = 1_024
    private static let maximumFindings = 512
    private static let maximumPreviewLength = 512

    private static let entitlementTerms = [
        "premium", "pro", "vip", "paid", "purchase", "purchased",
        "subscriber", "subscribed", "subscription", "membership", "member",
        "entitlement", "entitled", "unlock", "unlocked", "paywall",
        "accesslevel", "access_level", "plan", "tier", "trial", "expires",
        "expiration", "active_subscription", "activesubscription"
    ]

    private static let providerTerms = [
        "revenuecat", "purchases", "customerinfo", "customer_info",
        "entitlements", "active_subscriptions", "product_identifier",
        "storekit", "apphud", "adapty", "qonversion", "superwall"
    ]

    private static let excludedPathTerms = [
        "/_storekit/", "/storekit/", "/appstorereceipt", "/receipt"
    ]

    private struct Finding {
        let relativePath: String
        let keyPath: String
        let kind: String
        let valuePreview: String
        let score: Int

        var jsonObject: [String: Any] {
            [
                "relativePath": relativePath,
                "keyPath": keyPath,
                "kind": kind,
                "valuePreview": valuePreview,
                "score": score
            ]
        }
    }

    nonisolated static func scan(
        fileManager: FileManager = .default
    ) throws -> YarnPalResearchScanResult {
        guard let rawContainerPath = ContainerStore.resolveAppContainerPath(bundleID: bundleIdentifier) else {
            return .appUnavailable
        }

        let containerRoot = PatchPathValidator.canonicalFileURL(
            URL(fileURLWithPath: rawContainerPath, isDirectory: true)
        )
        let grantHandle = ContainerStore.grantContainerAccess(containerRoot.path)
        defer {
            if grantHandle >= 0 { bad_query_release(grantHandle) }
        }

        let files = candidateFiles(containerRoot: containerRoot, fileManager: fileManager)
        var findings: [Finding] = []
        var inspectedFiles = 0
        var interestingFiles: [[String: Any]] = []

        for fileURL in files.prefix(maximumFilesToInspect) {
            if findings.count >= maximumFindings { break }
            inspectedFiles += 1

            guard let relative = try? relativePath(for: fileURL, containerRoot: containerRoot),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                continue
            }

            let beforeCount = findings.count
            inspectStructuredData(
                data,
                relativePath: relative,
                findings: &findings
            )

            if findings.count == beforeCount,
               containsInterestingASCII(in: data) {
                let stat = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var entry: [String: Any] = [
                    "relativePath": relative,
                    "kind": "binary-or-database-keyword-hit",
                    "size": stat?.fileSize ?? data.count
                ]
                if let date = stat?.contentModificationDate {
                    entry["modifiedAt"] = ISO8601DateFormatter().string(from: date)
                }
                interestingFiles.append(entry)
            }
        }

        findings.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            return $0.keyPath < $1.keyPath
        }

        let report: [String: Any] = [
            "schema": 1,
            "target": [
                "app": "YarnPal",
                "bundleIdentifier": bundleIdentifier,
                "containerPath": containerRoot.path
            ],
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "mode": "read-only entitlement audit",
            "note": "This scan does not alter YarnPal files, StoreKit state, receipts, transactions, or account data.",
            "inspectedFiles": inspectedFiles,
            "findingCount": findings.count,
            "findings": findings.prefix(maximumFindings).map(\.jsonObject),
            "interestingBinaryOrDatabaseFiles": interestingFiles
        ]

        let encoded = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        let reportURL = try saveReport(encoded, fileManager: fileManager)
        return .reportCreated(
            reportURL: reportURL,
            inspectedFiles: inspectedFiles,
            candidates: findings.count + interestingFiles.count
        )
    }

    nonisolated private static func candidateFiles(
        containerRoot: URL,
        fileManager: FileManager
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let canonical = PatchPathValidator.canonicalFileURL(url)
            guard seen.insert(canonical.path).inserted else { return }
            guard isEligibleFile(canonical, fileManager: fileManager) else { return }
            result.append(canonical)
        }

        let primaryPreferences = containerRoot
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
        append(primaryPreferences)

        let roots = [
            containerRoot.appendingPathComponent("Library/Preferences", isDirectory: true),
            containerRoot.appendingPathComponent("Library/Application Support", isDirectory: true),
            containerRoot.appendingPathComponent("Library/Caches", isDirectory: true),
            containerRoot.appendingPathComponent("Documents", isDirectory: true),
            containerRoot.appendingPathComponent("tmp", isDirectory: true)
        ]

        for root in roots {
            guard result.count < maximumFilesToInspect,
                  fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey
                    ],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                  ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                if result.count >= maximumFilesToInspect { break }
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                )
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true else { continue }

                let ext = url.pathExtension.lowercased()
                let name = normalize(url.lastPathComponent)
                let structured = ["plist", "json", "db", "sqlite", "sqlite3", "dat"].contains(ext)
                let interestingName = entitlementTerms.contains(where: name.contains)
                    || providerTerms.contains(where: name.contains)
                    || name.contains("config")
                    || name.contains("cache")
                    || name.contains("userdefault")

                if structured || interestingName {
                    append(url)
                }
            }
        }

        return result
    }

    nonisolated private static func isEligibleFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumCandidateBytes else {
            return false
        }

        let path = url.path.lowercased()
        return !excludedPathTerms.contains(where: path.contains)
    }

    nonisolated private static func inspectStructuredData(
        _ data: Data,
        relativePath: String,
        findings: inout [Finding]
    ) {
        if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) {
            inspectValue(
                plist,
                keyPath: "$",
                relativePath: relativePath,
                findings: &findings
            )
            return
        }

        if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            inspectValue(
                json,
                keyPath: "$",
                relativePath: relativePath,
                findings: &findings
            )
        }
    }

    nonisolated private static func inspectValue(
        _ value: Any,
        keyPath: String,
        relativePath: String,
        findings: inout [Finding]
    ) {
        guard findings.count < maximumFindings else { return }

        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard findings.count < maximumFindings, let child = dictionary[key] else { break }
                let childPath = keyPath == "$" ? "$.\(key)" : "\(keyPath).\(key)"
                let score = signalScore(key: key, value: child)
                if score > 0, isPrimitive(child) {
                    findings.append(
                        Finding(
                            relativePath: relativePath,
                            keyPath: childPath,
                            kind: primitiveKind(child),
                            valuePreview: preview(child),
                            score: score
                        )
                    )
                }
                inspectValue(
                    child,
                    keyPath: childPath,
                    relativePath: relativePath,
                    findings: &findings
                )
            }
            return
        }

        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                guard findings.count < maximumFindings else { break }
                inspectValue(
                    child,
                    keyPath: "\(keyPath)[\(index)]",
                    relativePath: relativePath,
                    findings: &findings
                )
            }
            return
        }

        if let string = value as? String,
           let nestedData = string.data(using: .utf8),
           nestedData.count <= maximumCandidateBytes,
           let first = string.first,
           (first == "{" || first == "["),
           let nested = try? JSONSerialization.jsonObject(with: nestedData, options: []) {
            inspectValue(
                nested,
                keyPath: keyPath + "<json>",
                relativePath: relativePath,
                findings: &findings
            )
        }
    }

    nonisolated private static func signalScore(key: String, value: Any) -> Int {
        let normalizedKey = normalize(key)
        let keyHasEntitlement = entitlementTerms.contains(where: normalizedKey.contains)
        let keyHasProvider = providerTerms.contains(where: normalizedKey.contains)
        let normalizedValue = normalize(preview(value))
        let valueHasEntitlement = entitlementTerms.contains(where: normalizedValue.contains)
        let valueHasProvider = providerTerms.contains(where: normalizedValue.contains)

        var score = 0
        if keyHasEntitlement { score += 5 }
        if keyHasProvider { score += 4 }
        if valueHasEntitlement { score += 2 }
        if valueHasProvider { score += 2 }

        if normalizedKey.contains("is_premium") || normalizedKey.contains("ispremium") { score += 5 }
        if normalizedKey.contains("entitlement") { score += 5 }
        if normalizedKey.contains("subscription_status") || normalizedKey.contains("subscriptionstatus") { score += 4 }
        if normalizedKey.contains("active_subscription") || normalizedKey.contains("activesubscription") { score += 4 }
        if normalizedKey.contains("customerinfo") || normalizedKey.contains("customer_info") { score += 3 }
        return score
    }

    nonisolated private static func isPrimitive(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is Bool || value is Date || value is NSNull
    }

    nonisolated private static func primitiveKind(_ value: Any) -> String {
        if value is Bool { return "bool" }
        if value is NSNumber { return "number" }
        if value is String { return "string" }
        if value is Date { return "date" }
        if value is NSNull { return "null" }
        return "other"
    }

    nonisolated private static func preview(_ value: Any) -> String {
        let output: String
        if let string = value as? String {
            output = string
        } else if let date = value as? Date {
            output = ISO8601DateFormatter().string(from: date)
        } else {
            output = String(describing: value)
        }
        if output.count <= maximumPreviewLength { return output }
        return String(output.prefix(maximumPreviewLength)) + "…"
    }

    nonisolated private static func containsInterestingASCII(in data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let text = String(decoding: data.prefix(maximumCandidateBytes), as: UTF8.self).lowercased()
        return entitlementTerms.contains(where: text.contains)
            || providerTerms.contains(where: text.contains)
    }

    nonisolated private static func saveReport(
        _ data: Data,
        fileManager: FileManager
    ) throws -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = documents.appendingPathComponent("YarnPalResearch", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "YarnPal-entitlement-audit-\(formatter.string(from: Date())).json"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated private static func relativePath(
        for fileURL: URL,
        containerRoot: URL
    ) throws -> String {
        let root = PatchPathValidator.canonicalFileURL(containerRoot)
        let file = PatchPathValidator.canonicalFileURL(fileURL)
        guard file.path.hasPrefix(root.path + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        return try PatchPathValidator.canonicalRelativePath(relative)
    }

    nonisolated private static func normalize(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
