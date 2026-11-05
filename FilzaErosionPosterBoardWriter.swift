import Foundation
import AirliftFFI

/// Optional Erosion-style PosterBoard route for an already validated 3105
/// .tendies payload. This makes no claim that InstallationProxy grants write
/// access; every actual write must succeed in the paired Airlift runtime.
enum FilzaErosionPosterBoardWriter {
    enum Failure: LocalizedError {
        case pairingUnavailable
        case posterBoardUnavailable
        case invalidSource
        case partial(Int, String)

        var errorDescription: String? {
            switch self {
            case .pairingUnavailable:
                return "Pair with NFCARD and enable LocalDevVPN before applying wallpapers."
            case .posterBoardUnavailable:
                return "InstallationProxy did not return a valid PosterBoard data container."
            case .invalidSource:
                return "The imported wallpaper contains an unsupported or unsafe descriptor."
            case .partial(let count, let reason):
                return "Airlift applied \(count) descriptor(s) before failing: \(reason). " +
                    "Do not retry blindly; inspect PosterBoard before proceeding."
            }
        }
    }

    /// Use an actual read-only 3105 layout discovery when available, rather
    /// than forcing Erosion's generation 61 on every iOS release.
    /// Retain generation 61 only as the historical upstream fallback when
    /// the OS denies layout enumeration, and report that uncertainty.
    private static let upstreamFallbackGeneration = "61"
    private static func selectedGeneration(_ measured: String?) -> String {
        guard let measured, measured.count <= 4,
              !measured.isEmpty, measured.allSatisfy({ $0.isNumber }),
              Int(measured) != nil else { return upstreamFallbackGeneration }
        return measured
    }
    private static let allowedExtensions: Set<String> = [
        WallpaperPosterLayout.collectionsExtension,
        WallpaperPosterLayout.mercuryExtension,
        WallpaperPosterLayout.photosExtension
    ]

    static func apply(payload: TendiesPayload, preferredGeneration: String? = nil) async throws -> Int {
        guard let pairing = FilzaAirlift.pairedRecord() else {
            throw Failure.pairingUnavailable
        }
        guard !payload.descriptors.isEmpty,
              payload.descriptors.count <= WallpaperLabLimits.maximumDescriptorCount
        else { throw Failure.invalidSource }

        // Match Erosion: hidden system containers may not appear in an
        // unfiltered InstallationProxy app scan. Resolve this one bundle
        // explicitly, using the same pinned AirliftFFI lookup.
        let posterBoard = try await findPosterBoardContainer(pairing: pairing)
        let generation = selectedGeneration(preferredGeneration)
        FilzaDiagnosticsAppend(
            "WallpaperLab",
            "Airlift PosterBoard generation=\(generation) " +
            (preferredGeneration == nil
                ? "(upstream default, not measured; may fail on this iOS build)"
                : "(measured by 3105 local read-only access probe)")
        )

        let fm = FileManager.default
        var completed = 0
        for descriptor in payload.descriptors {
            guard allowedExtensions.contains(descriptor.extensionIdentifier),
                  descriptor.directoryURL.isFileURL,
                  descriptor.byteCount <= WallpaperLabLimits.maximumExpandedBytes,
                  descriptor.fileCount <= WallpaperLabLimits.maximumEntryCount
            else { throw Failure.invalidSource }

            // Validate the locally imported package again before remote use.
            try WallpaperLayoutScanner.validateDirectory(descriptor.directoryURL, fileManager: fm)
            let staging = fm.temporaryDirectory.appendingPathComponent(
                "FilzaPosterBoard-\(UUID().uuidString)", isDirectory: true
            )
            let destName = UUID().uuidString.uppercased()
            let source = staging.appendingPathComponent(destName, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: descriptor.directoryURL, to: source)
            try WallpaperDescriptorRewriter.randomize(in: source, fileManager: fm)

            let target = "\(posterBoard)/Library/Application Support/" +
                "PRBPosterExtensionDataStore/\(generation)/Extensions/" +
                "\(descriptor.extensionIdentifier)/descriptors"
            do {
                try await inject(
                    pairing: pairing, source: source.path,
                    targetParent: target, destination: destName
                )
                completed += 1
                FilzaDiagnosticsAppend(
                    "WallpaperLab",
                    "Erosion/Airlift wrote descriptor \(completed) to \(descriptor.extensionIdentifier)"
                )
            } catch {
                throw Failure.partial(completed, error.localizedDescription)
            }
        }
        FilzaDiagnosticsAppend(
            "WallpaperLab",
            "Erosion/Airlift installed \(completed) descriptors; refresh PosterBoard manually. " +
            "This remote operation does not create a local 3105 rollback receipt."
        )
        return completed
    }

    private static func findPosterBoardContainer(pairing: String) async throws -> String {
        let path = try await Task.detached(priority: .utility) { () throws -> String in
            var remote: UnsafeMutablePointer<CChar>?
            var err: UnsafeMutablePointer<CChar>?
            let rc = pairing.withCString { pair in
                "com.apple.PosterBoard".withCString { id in
                    al_find_app_container(pair, id, nil, nil, &remote, &err)
                }
            }
            let returned = remote.map { ptr -> String in
                defer { al_string_free(ptr) }
                return String(cString: ptr)
            }
            let error = err.map { ptr -> String in
                defer { al_string_free(ptr) }
                return String(cString: ptr)
            }
            guard rc == 0, let returned else {
                throw NSError(
                    domain: "FilzaErosionPosterBoard",
                    code: Int(rc),
                    userInfo: [
                        NSLocalizedDescriptionKey: error ??
                            "PosterBoard was not returned by paired InstallationProxy."
                    ]
                )
            }
            return returned
        }.value
        guard isValidContainer(path) else { throw Failure.posterBoardUnavailable }
        FilzaDiagnosticsAppend("WallpaperLab", "Paired PosterBoard container resolved")
        return path
    }

    private static func isValidContainer(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/private/") ?
            String(path.dropFirst("/private".count)) : path
        let prefixes = [
            "/var/mobile/Containers/Data/Application/",
            "/var/containers/Data/Application/"
        ]
        for prefix in prefixes where normalized.hasPrefix(prefix) {
            let suffix = String(normalized.dropFirst(prefix.count))
            return UUID(uuidString: suffix) != nil
        }
        return false
    }

    private static func inject(
        pairing: String, source: String,
        targetParent: String, destination: String
    ) async throws {
        try await Task.detached(priority: .utility) {
            var err: UnsafeMutablePointer<CChar>?
            let code = pairing.withCString { pair in
                source.withCString { path in
                    targetParent.withCString { parent in
                        destination.withCString { child in
                            al_exploit_inject_folder(
                                pair, path, parent, child, nil, nil, &err
                            )
                        }
                    }
                }
            }
            let detail = err.map { pointer -> String in
                defer { al_string_free(pointer) }
                return String(cString: pointer)
            }
            guard code == 0 else {
                throw NSError(
                    domain: "FilzaErosionPosterBoard",
                    code: Int(code),
                    userInfo: [
                        NSLocalizedDescriptionKey: detail ??
                            "Airlift folder injection failed; no success was reported."
                    ]
                )
            }
        }.value
    }
}
