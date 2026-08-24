import Foundation

@objc(FilzaYarnPalResearchBridge)
final class FilzaYarnPalResearchBridge: NSObject {
    private static var isPreparing = false

    @objc static func preparePatchIfPossible() {
        guard !isPreparing else { return }
        isPreparing = true

        Task.detached(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    isPreparing = false
                }
            }

            do {
                let result = try YarnPalOfflinePremiumResearch.preparePatch()
                switch result {
                case .created(let packageURL, let changedFiles, let changedFields):
                    log(
                        "yarnpal-research: created \(packageURL.lastPathComponent) " +
                        "files=\(changedFiles) fields=\(changedFields)"
                    )
                case .alreadyExists:
                    log("yarnpal-research: patch project already exists; leaving it unchanged")
                case .appUnavailable:
                    log("yarnpal-research: YarnPal app container is unavailable")
                case .noLocalGateFound(let inspectedFiles):
                    log(
                        "yarnpal-research: inspected \(inspectedFiles) candidate files; " +
                        "no mutable local premium gate was found"
                    )
                }
            } catch {
                log("yarnpal-research: generator failed: \(error.localizedDescription)")
            }
        }
    }
}

enum YarnPalResearchPreparationResult {
    case created(packageURL: URL, changedFiles: Int, changedFields: Int)
    case alreadyExists
    case appUnavailable
    case noLocalGateFound(inspectedFiles: Int)
}

enum YarnPalOfflinePremiumResearch {
    static let bundleIdentifier = "com.knitpal.knitcrochet"
    static let projectName = "YarnPal Offline Premium Research"

    private static let maximumCandidateBytes = 4 * 1_024 * 1_024
    private static let maximumFilesToInspect = 768
    private static let maximumRules = 24

    private static let positiveTerms = [
        "premium", "pro", "vip", "paid", "purchased", "purchase",
        "subscriber", "subscribed", "subscription", "membership", "member",
        "entitlement", "entitled", "unlocked", "unlock", "accesslevel",
        "access_level", "plan", "tier"
    ]

    private static let negativeTerms = [
        "expired", "isfree", "is_free", "freeuser", "free_user",
        "locked", "paywall", "needspurchase", "needs_purchase",
        "needssubscription", "needs_subscription"
    ]

    private static let excludedTerms = [
        "receipt", "transaction", "originaltransaction", "original_transaction",
        "productid", "product_id", "price", "currency", "token", "signature",
        "jwt", "authorization", "password", "accountid", "account_id"
    ]

    nonisolated static func preparePatch(
        fileManager: FileManager = .default
    ) throws -> YarnPalResearchPreparationResult {
        if PatchProjectLibrary.load(fileManager: fileManager).contains(where: {
            $0.project?.name == projectName
        }) {
            return .alreadyExists
        }

        guard let rawContainerPath = ContainerStore.resolveAppContainerPath(bundleID: bundleIdentifier) else {
            return .appUnavailable
        }

        let containerRoot = PatchPathValidator.canonicalFileURL(
            URL(fileURLWithPath: rawContainerPath, isDirectory: true)
        )
        let candidates = candidateFiles(containerRoot: containerRoot, fileManager: fileManager)

        var rules: [PatchRule] = []
        var changedFields = 0
        var inspectedFiles = 0

        for fileURL in candidates.prefix(maximumFilesToInspect) {
            guard rules.count < maximumRules else { break }
            inspectedFiles += 1

            guard let mutation = mutateFile(
                fileURL,
                containerRoot: containerRoot,
                fileManager: fileManager
            ) else {
                continue
            }

            let relativePath = try relativePath(for: fileURL, containerRoot: containerRoot)
            rules.append(
                PatchRule(
                    bundleID: bundleIdentifier,
                    relativePath: relativePath,
                    replacementFilename: "YarnPal-\(fileURL.lastPathComponent)",
                    replacementData: mutation.data
                )
            )
            changedFields += mutation.changedFields
        }

        guard !rules.isEmpty else {
            return .noLocalGateFound(inspectedFiles: inspectedFiles)
        }

        let now = Date()
        let project = PatchProject(
            name: projectName,
            createdAt: now,
            updatedAt: now,
            rules: rules
        )
        let encoded = try PatchPackageCodec.encodeNew(project: project, password: nil)
        let packageURL = try PatchProjectLibrary.save(
            data: encoded.data,
            projectName: project.name,
            fileManager: fileManager
        )

        return .created(
            packageURL: packageURL,
            changedFiles: rules.count,
            changedFields: changedFields
        )
    }

    private struct Mutation {
        let data: Data
        let changedFields: Int
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

        let preferencesURL = containerRoot
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
        append(preferencesURL)

        let roots = [
            containerRoot.appendingPathComponent("Library/Preferences", isDirectory: true),
            containerRoot.appendingPathComponent("Library/Application Support", isDirectory: true),
            containerRoot.appendingPathComponent("Documents", isDirectory: true)
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
                let name = url.lastPathComponent.lowercased()
                let interestingName = positiveTerms.contains(where: name.contains)
                    || name.contains("revenuecat")
                    || name.contains("customerinfo")
                    || name.contains("userdefault")
                    || name.contains("config")
                    || name.contains("cache")

                if ext == "plist" || ext == "json" || interestingName {
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
        if path.contains("/_storekit/") || path.hasSuffix("/appstorereceipt") {
            return false
        }
        return true
    }

    nonisolated private static func mutateFile(
        _ fileURL: URL,
        containerRoot: URL,
        fileManager: FileManager
    ) -> Mutation? {
        guard isEligibleFile(fileURL, fileManager: fileManager),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }

        if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: nil
        ) {
            if let dictionary = plist as? [String: Any], dictionary["$archiver"] != nil {
                return nil
            }

            var mutation = mutateValue(plist, keyHint: nil)
            if isPrimaryPreferencesFile(fileURL), var root = mutation.value as? [String: Any] {
                let injected = injectProbeDefaults(into: &root)
                mutation = (root, mutation.count + injected)
            }

            guard mutation.count > 0,
                  PropertyListSerialization.propertyList(mutation.value, isValidFor: .binary),
                  let encoded = try? PropertyListSerialization.data(
                    fromPropertyList: mutation.value,
                    format: .binary,
                    options: 0
                  ) else {
                return nil
            }
            return Mutation(data: encoded, changedFields: mutation.count)
        }

        if let json = try? JSONSerialization.jsonObject(from: data, options: [.mutableContainers]) {
            let mutation = mutateValue(json, keyHint: nil)
            guard mutation.count > 0,
                  JSONSerialization.isValidJSONObject(mutation.value),
                  let encoded = try? JSONSerialization.data(
                    withJSONObject: mutation.value,
                    options: [.sortedKeys]
                  ) else {
                return nil
            }
            return Mutation(data: encoded, changedFields: mutation.count)
        }

        return nil
    }

    nonisolated private static func mutateValue(
        _ value: Any,
        keyHint: String?
    ) -> (value: Any, count: Int) {
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            var count = 0
            for (key, child) in dictionary {
                let mutation = mutateValue(child, keyHint: key)
                output[key] = mutation.value
                count += mutation.count
            }
            return (output, count)
        }

        if let array = value as? [Any] {
            var output: [Any] = []
            var count = 0
            output.reserveCapacity(array.count)
            for child in array {
                let mutation = mutateValue(child, keyHint: keyHint)
                output.append(mutation.value)
                count += mutation.count
            }
            return (output, count)
        }

        guard let keyHint else {
            return (value, 0)
        }
        let normalizedKey = normalize(keyHint)
        guard !excludedTerms.contains(where: normalizedKey.contains) else {
            return (value, 0)
        }

        let isNegativeGate = negativeTerms.contains(where: normalizedKey.contains)
        let isPositiveGate = positiveTerms.contains(where: normalizedKey.contains)
        guard isNegativeGate || isPositiveGate else {
            return (value, 0)
        }

        if let bool = value as? Bool {
            let desired = isNegativeGate ? false : true
            return bool == desired ? (value, 0) : (desired, 1)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                let desired = !isNegativeGate
                return number.boolValue == desired ? (value, 0) : (desired, 1)
            }
            let desired = isNegativeGate ? 0 : 1
            return number.intValue == desired ? (value, 0) : (NSNumber(value: desired), 1)
        }

        if let string = value as? String {
            if let nested = mutateJSONString(string) {
                return (nested.value, nested.count)
            }

            let normalizedValue = normalize(string)
            if isNegativeGate {
                let negativeValues = ["true", "1", "yes", "locked", "expired", "required"]
                if negativeValues.contains(normalizedValue) {
                    return ("false", 1)
                }
                return (value, 0)
            }

            let inactiveValues = [
                "false", "0", "no", "free", "basic", "inactive", "expired",
                "none", "null", "locked", "unsubscribed", "not_subscribed"
            ]
            guard inactiveValues.contains(normalizedValue) else {
                return (value, 0)
            }

            if normalizedKey.contains("tier") || normalizedKey.contains("plan") {
                return ("premium", 1)
            }
            if normalizedKey.contains("status") || normalizedKey.contains("subscription") {
                return ("active", 1)
            }
            return ("true", 1)
        }

        return (value, 0)
    }

    nonisolated private static func mutateJSONString(
        _ string: String
    ) -> (value: String, count: Int)? {
        guard let data = string.data(using: .utf8),
              data.count <= maximumCandidateBytes,
              let first = string.first,
              first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(from: data, options: [.mutableContainers]) else {
            return nil
        }

        let mutation = mutateValue(object, keyHint: nil)
        guard mutation.count > 0,
              JSONSerialization.isValidJSONObject(mutation.value),
              let encoded = try? JSONSerialization.data(
                withJSONObject: mutation.value,
                options: [.sortedKeys]
              ),
              let output = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return (output, mutation.count)
    }

    nonisolated private static func injectProbeDefaults(
        into dictionary: inout [String: Any]
    ) -> Int {
        let probes: [String: Any] = [
            "isPremium": true,
            "hasPremium": true,
            "premium": true,
            "isPro": true,
            "isSubscribed": true,
            "subscriptionActive": true,
            "isPaidUser": true,
            "hasActiveSubscription": true
        ]

        var count = 0
        for (key, value) in probes where dictionary[key] == nil {
            dictionary[key] = value
            count += 1
        }
        return count
    }

    nonisolated private static func isPrimaryPreferencesFile(_ url: URL) -> Bool {
        url.lastPathComponent == "\(bundleIdentifier).plist"
            && url.deletingLastPathComponent().lastPathComponent == "Preferences"
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
