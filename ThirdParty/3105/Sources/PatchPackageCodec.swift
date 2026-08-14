import CommonCrypto
import CryptoKit
import Foundation
import Security

enum PatchPackageCodec {
    private static let magic = Data("3105PATCH\0".utf8)
    private static let schemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let packageID: UUID
        let isPasswordProtected: Bool
        let kdfSalt: Data?
        let kdfIterations: Int?
        let wrappedContentKey: Data?
        let publicContentKey: Data?
        let keyFingerprint: Data
        let encryptedPayload: Data
    }

    private struct Payload: Codable {
        let project: PatchProject
        let replacementDigests: [String: Data]
    }

    static func encodeNew(
        project: PatchProject,
        password: String?,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        try validate(project)
        let contentKey = try randomData(count: 32)
        let protected = !(password ?? "").isEmpty
        let salt: Data?
        let iterations: Int?
        let wrappedKey: Data?
        let publicKey: Data?

        if protected {
            guard let password, password.utf8.count <= PatchPackageLimits.maximumPasswordBytes,
                  kdfIterations >= PatchPackageLimits.minimumKDFIterations,
                  kdfIterations <= PatchPackageLimits.maximumKDFIterations
            else {
                throw PatchPackageError.invalidProject
            }
            salt = try randomData(count: 16)
            iterations = kdfIterations
            let wrappingKey = try deriveKey(password: password, salt: salt!, iterations: kdfIterations)
            wrappedKey = try seal(contentKey, key: wrappingKey, aad: keyAAD(for: project.id))
            publicKey = nil
        } else {
            salt = nil
            iterations = nil
            wrappedKey = nil
            publicKey = contentKey
        }

        let envelope = try makeEnvelope(
            project: project,
            contentKey: contentKey,
            isPasswordProtected: protected,
            kdfSalt: salt,
            kdfIterations: iterations,
            wrappedContentKey: wrappedKey,
            publicContentKey: publicKey
        )
        return EncodedPatchPackage(data: try serialize(envelope), contentKey: contentKey)
    }

    static func inspect(_ data: Data) throws -> PatchPackageSummary {
        let envelope = try parseEnvelope(data)
        return PatchPackageSummary(
            packageID: envelope.packageID,
            isPasswordProtected: envelope.isPasswordProtected,
            keyFingerprint: envelope.keyFingerprint
        )
    }

    static func decode(_ data: Data, password: String?) throws -> DecodedPatchPackage {
        do {
            let envelope = try parseEnvelope(data)
            let contentKey: Data
            if envelope.isPasswordProtected {
                guard let password,
                      !password.isEmpty,
                      password.utf8.count <= PatchPackageLimits.maximumPasswordBytes,
                      let salt = envelope.kdfSalt,
                      let iterations = envelope.kdfIterations,
                      let wrappedKey = envelope.wrappedContentKey
                else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
                let wrappingKey = try deriveKey(password: password, salt: salt, iterations: iterations)
                contentKey = try open(wrappedKey, key: wrappingKey, aad: keyAAD(for: envelope.packageID))
            } else {
                guard let storedKey = envelope.publicContentKey else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
                contentKey = storedKey
            }
            return try decode(envelope: envelope, contentKey: contentKey)
        } catch let error as PatchPackageError {
            switch error {
            case .unsupportedFormat, .unsupportedVersion, .sizeLimitExceeded:
                throw error
            default:
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
    }

    static func decode(_ data: Data, contentKey: Data) throws -> DecodedPatchPackage {
        do {
            let envelope = try parseEnvelope(data)
            return try decode(envelope: envelope, contentKey: contentKey)
        } catch let error as PatchPackageError {
            switch error {
            case .unsupportedFormat, .unsupportedVersion, .sizeLimitExceeded:
                throw error
            default:
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
    }

    static func update(
        _ originalData: Data,
        project: PatchProject,
        contentKey: Data
    ) throws -> Data {
        let oldEnvelope = try parseEnvelope(originalData)
        guard project.id == oldEnvelope.packageID,
              fingerprint(contentKey) == oldEnvelope.keyFingerprint
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        try validate(project)
        let envelope = try makeEnvelope(
            project: project,
            contentKey: contentKey,
            isPasswordProtected: oldEnvelope.isPasswordProtected,
            kdfSalt: oldEnvelope.kdfSalt,
            kdfIterations: oldEnvelope.kdfIterations,
            wrappedContentKey: oldEnvelope.wrappedContentKey,
            publicContentKey: oldEnvelope.publicContentKey
        )
        return try serialize(envelope)
    }

    private static func makeEnvelope(
        project: PatchProject,
        contentKey: Data,
        isPasswordProtected: Bool,
        kdfSalt: Data?,
        kdfIterations: Int?,
        wrappedContentKey: Data?,
        publicContentKey: Data?
    ) throws -> Envelope {
        let digests = Dictionary(uniqueKeysWithValues: project.rules.map {
            ($0.id.uuidString, Data(SHA256.hash(data: $0.replacementData)))
        })
        let payload = Payload(project: project, replacementDigests: digests)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadData = try encoder.encode(payload)
        let encryptedPayload = try seal(payloadData, key: contentKey, aad: payloadAAD(for: project.id))

        return Envelope(
            schemaVersion: schemaVersion,
            packageID: project.id,
            isPasswordProtected: isPasswordProtected,
            kdfSalt: kdfSalt,
            kdfIterations: kdfIterations,
            wrappedContentKey: wrappedContentKey,
            publicContentKey: publicContentKey,
            keyFingerprint: fingerprint(contentKey),
            encryptedPayload: encryptedPayload
        )
    }

    private static func decode(envelope: Envelope, contentKey: Data) throws -> DecodedPatchPackage {
        guard contentKey.count == 32,
              fingerprint(contentKey) == envelope.keyFingerprint
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let payloadData = try open(
            envelope.encryptedPayload,
            key: contentKey,
            aad: payloadAAD(for: envelope.packageID)
        )
        let decoder = PropertyListDecoder()
        let payload = try decoder.decode(Payload.self, from: payloadData)
        guard payload.project.id == envelope.packageID else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        try validate(payload.project)
        guard payload.replacementDigests.count == payload.project.rules.count else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        for rule in payload.project.rules {
            let actual = Data(SHA256.hash(data: rule.replacementData))
            guard payload.replacementDigests[rule.id.uuidString] == actual else {
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        }
        return DecodedPatchPackage(project: payload.project, contentKey: contentKey)
    }

    static func validate(_ project: PatchProject) throws {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 120, !project.rules.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        guard project.rules.count <= PatchPackageLimits.maximumRuleCount else {
            throw PatchPackageError.sizeLimitExceeded
        }

        var targets = Set<String>()
        var ruleIDs = Set<UUID>()
        var totalBytes = 0
        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard bundleID == rule.bundleID,
                  relativePath == rule.relativePath,
                  ruleIDs.insert(rule.id).inserted,
                  !rule.replacementFilename.isEmpty,
                  rule.replacementFilename.utf8.count <= 255,
                  !rule.replacementFilename.contains("/"),
                  !rule.replacementFilename.contains("\\"),
                  !rule.replacementFilename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw PatchPackageError.invalidProject
            }
            guard rule.replacementData.count <= PatchPackageLimits.maximumReplacementBytes else {
                throw PatchPackageError.sizeLimitExceeded
            }
            let targetKey = bundleID + "\0" + relativePath
            guard targets.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(rule.replacementData.count)
            guard !overflow, nextTotal <= PatchPackageLimits.maximumTotalReplacementBytes else {
                throw PatchPackageError.sizeLimitExceeded
            }
            totalBytes = nextTotal
        }
    }

    private static func parseEnvelope(_ data: Data) throws -> Envelope {
        guard data.count <= PatchPackageLimits.maximumPackageBytes,
              data.count > magic.count,
              data.prefix(magic.count) == magic
        else {
            if data.count > PatchPackageLimits.maximumPackageBytes {
                throw PatchPackageError.sizeLimitExceeded
            }
            throw PatchPackageError.unsupportedFormat
        }
        let encoded = data.dropFirst(magic.count)
        let envelope: Envelope
        do {
            envelope = try PropertyListDecoder().decode(Envelope.self, from: Data(encoded))
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw PatchPackageError.unsupportedVersion
        }
        guard envelope.keyFingerprint.count == 32,
              envelope.encryptedPayload.count >= 28
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        if envelope.isPasswordProtected {
            guard envelope.publicContentKey == nil,
                  envelope.kdfSalt?.count == 16,
                  let iterations = envelope.kdfIterations,
                  iterations >= PatchPackageLimits.minimumKDFIterations,
                  iterations <= PatchPackageLimits.maximumKDFIterations,
                  envelope.wrappedContentKey != nil
            else {
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } else {
            guard envelope.kdfSalt == nil,
                  envelope.kdfIterations == nil,
                  envelope.wrappedContentKey == nil,
                  envelope.publicContentKey?.count == 32
            else {
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        }
        return envelope
    }

    private static func serialize(_ envelope: Envelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(envelope)
        var result = magic
        result.append(body)
        guard result.count <= PatchPackageLimits.maximumPackageBytes else {
            throw PatchPackageError.sizeLimitExceeded
        }
        return result
    }

    private static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        guard let combined = sealed.combined else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return combined
    }

    private static func open(_ ciphertext: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        guard iterations >= PatchPackageLimits.minimumKDFIterations,
              iterations <= PatchPackageLimits.maximumKDFIterations else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let passwordData = Data(password.utf8)
        let derivedKeyLength = 32
        var output = Data(count: derivedKeyLength)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            passwordData.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return output
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PatchPackageError.invalidProject
        }
        return data
    }

    private static func fingerprint(_ key: Data) -> Data {
        Data(SHA256.hash(data: key))
    }

    private static func keyAAD(for packageID: UUID) -> Data {
        Data("3105PATCH/v1/key/\(packageID.uuidString)".utf8)
    }

    private static func payloadAAD(for packageID: UUID) -> Data {
        Data("3105PATCH/v1/payload/\(packageID.uuidString)".utf8)
    }
}
