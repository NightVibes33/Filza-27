import Foundation
import SwiftUI
import UIKit

struct FilzaIPAExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum FilzaAppIPAExportError: LocalizedError {
    case bundlePathUnavailable
    case bundleUnreadable
    case archiveFailed

    var errorDescription: String? {
        switch self {
        case .bundlePathUnavailable:
            return "3105 could not resolve this app's installed .app bundle path."
        case .bundleUnreadable:
            return "The installed app bundle is not readable from the current Filza access context."
        case .archiveFailed:
            return "The app bundle could not be repackaged into an IPA."
        }
    }
}

enum FilzaAppIPAExporter {
    nonisolated static func repackage(
        bundleID: String,
        displayName: String,
        version: String
    ) throws -> URL {
        guard let bundlePath = filzaAppBundlePathForBundleID(bundleID),
              !bundlePath.isEmpty else {
            throw FilzaAppIPAExportError.bundlePathUnavailable
        }

        let appURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let fileManager = FileManager.default

        // Keep the bad_query lease alive for the entire archive operation when
        // this build can grant traversal to the installed bundle. If the bundle
        // is already directly readable, a failed lease is harmless.
        let lease = ContainerStore.grantContainerAccess(bundlePath)
        defer {
            if lease >= 0 {
                bad_query_release(lease)
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundlePath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? fileManager.contentsOfDirectory(atPath: bundlePath)) != nil else {
            throw FilzaAppIPAExportError.bundleUnreadable
        }

        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("3105-IPA-Exports", isDirectory: true)
        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let safeName = sanitizedFilename(displayName.isEmpty ? bundleID : displayName)
        let safeVersion = sanitizedFilename(version)
        let suffix = safeVersion.isEmpty ? "" : "-\(safeVersion)"
        let destinationURL = exportDirectory
            .appendingPathComponent("\(safeName)\(suffix).ipa")

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            _ = try ZIPArchiveWriter.writeIPA(
                appBundleURL: appURL,
                to: destinationURL,
                fileManager: fileManager
            )
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw FilzaAppIPAExportError.archiveFailed
        }
    }

    nonisolated private static func sanitizedFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App" : cleaned
    }
}

struct FilzaIPAExportDocumentPicker: UIViewControllerRepresentable {
    let item: FilzaIPAExportItem
    let completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forExporting: [item.url],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion()
        }
    }
}
