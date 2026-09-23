import SwiftUI
@preconcurrency import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Stable image picker used only by AirCard's individual passcode-key flow.
///
/// AirCard is embedded inside Filza's own page sheet. The upstream SwiftUI
/// PhotosPicker path is therefore a nested presentation plus Transferable load.
/// This wrapper uses PHPicker directly, loads bytes instead of a full-resolution
/// UIImage, downsamples before publishing state, and lets SwiftUI own only one
/// ordinary sheet.
struct FilzaAirCardIndividualKeyPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (UIImage) -> Void
        private let onCancel: () -> Void
        private var completed = false

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !completed else { return }
            completed = true

            guard let provider = results.first?.itemProvider else {
                DispatchQueue.main.async { self.onCancel() }
                return
            }

            let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            }) ?? UTType.image.identifier

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data,
                      !data.isEmpty,
                      let image = ImageEngine.safeImageFromData(data, maxDimension: 768) else {
                    DispatchQueue.main.async { self.onCancel() }
                    return
                }

                DispatchQueue.main.async {
                    self.onPick(image)
                }
            }
        }
    }
}
