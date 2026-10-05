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

                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 38, height: 5)
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        let vertical = value.translation.height
                        let horizontal = abs(value.translation.width)
                        let predicted = value.predictedEndTranslation.height

                        // Custom embedded windows may only be dismissed by a
                        // deliberate downward swipe that begins in this top bar.
                        // Scroll/drag gestures inside the hosted app never close it.
                        guard vertical > 90,
                              predicted > 125,
                              horizontal < max(90, vertical * 0.85) else {
                            return
                        }
                        dismiss()
                    }
            )

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
        // Disable UIKit's whole-sheet pan-to-dismiss. The only swipe dismissal
        // lives on FilzaEmbeddedPanel's top bar above.
        controller.isModalInPresentation = true
        guard let sheet = controller.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = false
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }
}
