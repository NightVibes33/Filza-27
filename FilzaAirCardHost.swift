import Foundation
import SwiftUI
import UIKit
@preconcurrency import PhotosUI
import UniformTypeIdentifiers
import AirliftFFI

private enum AirCardEmbeddedRuntime {
    static var configured = false

    @MainActor
    static func configureOnce() {
        guard !configured else { return }
        configured = true
        al_log_init({ _, msg in
            guard let msg else { return }
            let line = String(cString: msg)
            DispatchQueue.main.async { AppViewModel.sharedLogSink?(line) }
        }, nil)
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)
    }
}

@_silgen_name("ALGetGrappaToken")
private func ALGetGrappaToken(
    _ a: UInt32, _ b: UInt32, _ c: UInt32,
    _ d: UnsafeMutablePointer<UInt8>?, _ e: Int,
    _ f: UnsafeMutablePointer<Int>?,
    _ g: UnsafeMutablePointer<CChar>?, _ h: Int
) -> Int32

@MainActor
final class FilzaAirCardHostPresenter: NSObject, ObservableObject,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate {

    weak var hostViewController: UIViewController?
    private weak var pendingViewModel: AppViewModel?
    private var pendingDigit: String?

    func presentIndividualKeySource(for digit: String, viewModel: AppViewModel) {
        guard let host = hostViewController else {
            viewModel.errorMessage = "AirCard host is unavailable."
            return
        }
        guard host.presentedViewController == nil else {
            viewModel.errorMessage = "Finish the current AirCard dialog before choosing a key image."
            return
        }

        pendingDigit = digit
        pendingViewModel = viewModel

        let alert = UIAlertController(
            title: "Choose Key \(digit) Image Source",
            message: nil,
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            alert?.dismiss(animated: true) { self.presentPhotoPicker() }
        })
        alert.addAction(UIAlertAction(title: "Choose from Files…", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            alert?.dismiss(animated: true) { self.presentDocumentPicker() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.clearPending()
        })

        if let popover = alert.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(
                x: host.view.bounds.midX,
                y: host.view.bounds.maxY - 1,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        host.present(alert, animated: true)
    }

    private func presentPhotoPicker() {
        guard let host = hostViewController,
              pendingDigit != nil,
              pendingViewModel != nil else {
            clearPending()
            return
        }

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        host.present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        guard let host = hostViewController,
              pendingDigit != nil,
              pendingViewModel != nil else {
            clearPending()
            return
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                .image, .png, .jpeg, .heic,
                UTType(filenameExtension: "webp") ?? .image,
                UTType(filenameExtension: "tiff") ?? .image
            ],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .fullScreen
        host.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider,
              let digit = pendingDigit,
              let viewModel = pendingViewModel else {
            picker.dismiss(animated: true)
            clearPending()
            return
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier

        picker.dismiss(animated: true)

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self, weak viewModel] data, _ in
            guard let self,
                  let viewModel,
                  let data,
                  !data.isEmpty,
                  let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) else {
                DispatchQueue.main.async {
                    self?.pendingViewModel?.errorMessage = "Could not load the selected key image."
                    self?.clearPending()
                }
                return
            }

            DispatchQueue.main.async {
                guard self.pendingDigit == digit,
                      self.pendingViewModel === viewModel else {
                    self.clearPending()
                    return
                }
                viewModel.setIndividualKey(digit: digit, image: image)
                self.clearPending()
            }
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first,
              let digit = pendingDigit,
              let viewModel = pendingViewModel else {
            clearPending()
            return
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url),
              let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) else {
            viewModel.errorMessage = "Could not load the selected key image."
            clearPending()
            return
        }

        viewModel.setIndividualKey(digit: digit, image: image)
        clearPending()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        clearPending()
    }

    private func clearPending() {
        pendingDigit = nil
        pendingViewModel = nil
    }
}

private struct AirCardEmbeddedRoot: View {
    @StateObject private var vm = AppViewModel()
    let hostPresenter: FilzaAirCardHostPresenter

    var body: some View {
        FilzaEmbeddedPanel {
            AirCardContentView()
                .environmentObject(vm)
                .environmentObject(hostPresenter)
                .task { _ = await LocalNetworkAuthorization().request(timeout: 2.5) }
        }
    }
}

@MainActor
@objc(AirCardEmbeddedHostFactory)
public final class AirCardEmbeddedHostFactory: NSObject {
    @objc
    public static func makeViewController() -> UIViewController {
        AirCardEmbeddedRuntime.configureOnce()

        let presenter = FilzaAirCardHostPresenter()
        let controller = UIHostingController(
            rootView: AirCardEmbeddedRoot(hostPresenter: presenter)
        )
        presenter.hostViewController = controller
        controller.title = "AirCard"
        FilzaEmbeddedPanelPresentation.configure(controller)
        return controller
    }
}
