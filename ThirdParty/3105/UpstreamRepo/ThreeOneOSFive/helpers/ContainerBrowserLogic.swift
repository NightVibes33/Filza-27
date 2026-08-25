import Foundation

enum ContainerDiscoveryMerger {
    static func canonicalPath(_ rawPath: String) -> String {
        var path = (rawPath as NSString).standardizingPath
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func merge<Element>(
        enumerated: [Element],
        identified: [Element],
        path: (Element) -> String
    ) -> [Element] {
        var result: [Element] = []
        var indexByPath: [String: Int] = [:]

        for element in enumerated {
            let key = canonicalPath(path(element))
            guard !key.isEmpty, indexByPath[key] == nil else { continue }
            indexByPath[key] = result.count
            result.append(element)
        }

        for element in identified {
            let key = canonicalPath(path(element))
            guard !key.isEmpty else { continue }
            if let index = indexByPath[key] {
                result[index] = element
            } else {
                indexByPath[key] = result.count
                result.append(element)
            }
        }
        return result
    }
}

enum ContainerAccessPolicy {
    static func shouldRequestGrant(isRoot: Bool) -> Bool {
        isRoot
    }

    static func shouldAttemptMCM(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return false
        }
        return UUID(uuidString: bundleID) == nil
    }
}

enum ContainerBundleCandidateResolver {
    static func candidates(
        savedStateNames: [String],
        preferenceFileNames: [String],
        artifactNames: [String] = []
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ rawIdentifier: String, allowAppleIdentifier: Bool) {
            let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidBundleIdentifier(identifier),
                  !identifier.hasPrefix("group."),
                  !identifier.hasPrefix("systemgroup."),
                  (allowAppleIdentifier || !identifier.hasPrefix("com.apple.")),
                  seen.insert(identifier).inserted else {
                return
            }
            result.append(identifier)
        }

        for name in savedStateNames where name.hasSuffix(".savedState") {
            append(String(name.dropLast(".savedState".count)), allowAppleIdentifier: true)
        }

        for name in preferenceFileNames where name.hasSuffix(".plist") {
            append(String(name.dropLast(".plist".count)), allowAppleIdentifier: false)
        }

        for name in artifactNames {
            if name.hasSuffix(".binarycookies") {
                append(String(name.dropLast(".binarycookies".count)), allowAppleIdentifier: true)
            } else if let separator = name.range(of: " - ") {
                append(String(name[..<separator.lowerBound]), allowAppleIdentifier: true)
            } else {
                append(name, allowAppleIdentifier: true)
            }
        }

        return result
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.contains("."),
              !value.contains(".."),
              value.first != ".",
              value.last != "." else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func confirmedCandidate(
        candidates: [String],
        launchServicesIdentifiers: Set<String>
    ) -> String? {
        candidates.first { launchServicesIdentifiers.contains($0) }
    }
}

enum LaunchServicesCandidateExtractor {
    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }

    static func identifiers(from data: Data, limit: Int = 65_536) -> [String] {
        guard limit > 0, !data.isEmpty else { return [] }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var result: [String] = []
            var seen = Set<String>()
            var index = 0

            while index < bytes.count, result.count < limit {
                guard isIdentifierByte(bytes[index]) else {
                    index += 1
                    continue
                }

                let start = index
                while index < bytes.count, isIdentifierByte(bytes[index]) {
                    index += 1
                }
                let length = index - start
                guard (3...255).contains(length),
                      let identifier = String(bytes: bytes[start..<index], encoding: .utf8),
                      ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier),
                      !identifier.hasPrefix("group."),
                      !identifier.hasPrefix("systemgroup."),
                      seen.insert(identifier).inserted else {
                    continue
                }
                result.append(identifier)
            }

            return result
        }
    }
}

enum MHAIdentifierCatalog {
    static func identifiers(
        dynamic: [String],
        installed: [String],
        research: [String],
        custom: [String],
        launchServices: [String],
        limit: Int = 65_536
    ) -> [String] {
        guard limit > 0 else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        for source in [dynamic, installed, research, custom, launchServices] {
            for rawIdentifier in source where result.count < limit {
                let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard ContainerBundleCandidateResolver.isValidBundleIdentifier(identifier),
                      !identifier.hasPrefix("group."),
                      !identifier.hasPrefix("systemgroup."),
                      seen.insert(identifier).inserted else {
                    continue
                }
                result.append(identifier)
            }
            if result.count == limit { break }
        }
        return result
    }
}

enum AppDataCatalogMerger {
    static func merge<Element>(
        identified: [Element],
        fallback: [Element],
        identifier: (Element) -> String,
        path: (Element) -> String
    ) -> [Element] {
        var result: [Element] = []
        var seenIdentifiers = Set<String>()
        var identifiedPaths = Set<String>()

        for element in identified {
            let bundleID = identifier(element)
            let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path(element))
            guard !bundleID.isEmpty,
                  !canonicalPath.isEmpty,
                  seenIdentifiers.insert(bundleID).inserted else {
                continue
            }
            identifiedPaths.insert(canonicalPath)
            result.append(element)
        }

        for element in fallback {
            let bundleID = identifier(element)
            let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path(element))
            guard !bundleID.isEmpty,
                  !canonicalPath.isEmpty,
                  !identifiedPaths.contains(canonicalPath),
                  seenIdentifiers.insert(bundleID).inserted else {
                continue
            }
            result.append(element)
        }
        return result
    }
}

enum ContainerPresentationPolicy {
    static func shouldShow(bundleID: String) -> Bool {
        UUID(uuidString: bundleID) == nil
    }
}

enum AppDisplayNamePolicy {
    static func resolve(bundleID: String, candidates: [String?]) -> String {
        let fallback = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        for rawCandidate in candidates {
            guard let rawCandidate else { continue }
            let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.utf8.count <= 256,
                  candidate.rangeOfCharacter(from: .controlCharacters) == nil,
                  candidate.caseInsensitiveCompare(fallback) != .orderedSame,
                  UUID(uuidString: candidate) == nil else {
                continue
            }
            return candidate
        }
        return fallback
    }
}

struct ApplicationBundleMetadata: Equatable {
    let bundleID: String
    let displayName: String
    let version: String
}

enum ApplicationBundleMetadataReader {
    static func metadata(
        from plistData: Data,
        localizedInfo: [String: Any]? = nil
    ) -> ApplicationBundleMetadata? {
        guard let info = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
              let rawBundleID = info["CFBundleIdentifier"] as? String else {
            return nil
        }

        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID) else {
            return nil
        }

        let displayName = AppDisplayNamePolicy.resolve(
            bundleID: bundleID,
            candidates: [
                localizedInfo?["CFBundleDisplayName"] as? String,
                localizedInfo?["CFBundleName"] as? String,
                info["CFBundleDisplayName"] as? String,
                info["CFBundleName"] as? String
            ]
        )
        let version = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ApplicationBundleMetadata(
            bundleID: bundleID,
            displayName: displayName,
            version: version
        )
    }
}
