import SwiftUI
import UIKit

/// Canonical presentation chrome for third-party apps embedded in Filza.
///
/// 3105 defines the UX contract: a large in-app page sheet with a visible
/// grabber and a persistent material Close row above the third-party content.
/// Mond and ByeTunes use this exact same container so presentation and exit
/// behavior cannot drift between integrations. Filza's own UI is not changed.
struct FilzaThirdPartyEmbeddedContainer<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }

                Spacer()
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            content
        }
    }
}

@MainActor
@discardableResult
func FilzaConfigureThirdPartySheet(
    _ controller: UIViewController,
    title: String
) -> UIViewController {
    controller.title = title
    controller.modalPresentationStyle = .pageSheet

    if let sheet = controller.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }

    return controller
}
