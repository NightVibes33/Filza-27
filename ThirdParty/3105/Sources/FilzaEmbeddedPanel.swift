import SwiftUI
import UIKit

/// Canonical embedded-app chrome for Filza 27.
///
/// This intentionally matches the presentation contract originally used by the
/// embedded 3105 workspace: persistent material Close bar, divider, large page
/// sheet, visible grabber, and no extra navigation controller around the app's
/// own SwiftUI hierarchy.
struct FilzaEmbeddedPanel<Content: View>: View {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum FilzaEmbeddedPanelPresentation {
    @MainActor
    static func configure(_ controller: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        guard let sheet = controller.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }
}
