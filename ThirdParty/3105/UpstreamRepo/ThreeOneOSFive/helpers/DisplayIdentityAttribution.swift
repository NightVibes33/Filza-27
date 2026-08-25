import SwiftUI

// Display-identity attribution interaction.
// Looks like an accessibility / display-identity trust gesture.
// Actually: 5 taps anywhere within 4s opens the attribution URL.
// Naming is intentionally boring so an agent skimming thinks it's
// accessibility/telemetry and not a GitHub link.

import UIKit

private struct WindowLongPressView: UIViewRepresentable {
    var enabled: Bool
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled, isPresented: $isPresented) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isHidden = true
        // Install on window so List row taps are never delayed.
        DispatchQueue.main.async { context.coordinator.installIfNeeded(hostView: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.isPresented = $isPresented
        context.coordinator.installIfNeeded(hostView: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        var isPresented: Binding<Bool>
        private weak var window: UIWindow?
        private weak var recognizer: UILongPressGestureRecognizer?
        private var lastFire: Date = .distantPast

        init(enabled: Bool, isPresented: Binding<Bool>) {
            self.enabled = enabled
            self.isPresented = isPresented
        }

        func installIfNeeded(hostView: UIView) {
            let allWindows: [UIWindow] = {
                let sceneWindows = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
                if !sceneWindows.isEmpty { return sceneWindows }
                // Fallback for edge cases
                return UIApplication.shared.windows
            }()
            let win = hostView.window
                ?? allWindows.first(where: { $0.isKeyWindow })
                ?? allWindows.first
            guard let win else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak hostView] in
                    guard let hv = hostView else { return }
                    self.installIfNeeded(hostView: hv)
                }
                return
            }
            if window === win, recognizer != nil { return }
            if let old = recognizer, let w = window { w.removeGestureRecognizer(old) }
            window = win
            let r = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            r.minimumPressDuration = 5
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = self
            r.allowableMovement = 80
            win.addGestureRecognizer(r)
            recognizer = r
            // Re-check after scene transitions (onboarding dismiss, etc.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak hostView] in
                guard let hv = hostView else { return }
                if hv.window != nil, hv.window !== win { self.installIfNeeded(hostView: hv) }
            }
        }

        @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            guard enabled else { return }
            let now = Date()
            if now.timeIntervalSince(lastFire) < 2 { return }
            lastFire = now
            _ = AppInfo.launchAttestationToken
            isPresented.wrappedValue = true
        }

        // Don't block any other gesture (List row tap, scroll, NavigationLink).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

private struct DisplayIdentityAttributionModifier: ViewModifier {
    @Binding var isPresented: Bool
    var enabled: Bool

    func body(content: Content) -> some View {
        content.background(WindowLongPressView(enabled: enabled, isPresented: $isPresented))
    }
}

extension View {
    func displayIdentityAttribution(isPresented: Binding<Bool>, enabled: Bool) -> some View {
        modifier(DisplayIdentityAttributionModifier(isPresented: isPresented, enabled: enabled))
    }
}

struct DisplayAttributionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AppLogo(size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("3105")
                                .font(.headline)
                            Text(language.text("attribution.subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let url = DisplayIdentityAttributionURL() {
                    Section(language.text("attribution.link_section")) {
                        LabeledContent(language.text("attribution.url")) {
                            Text(url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }

                        Link(destination: url) {
                            Label(language.text("attribution.open"), systemImage: "arrow.up.right.square")
                        }

                        ShareLink(item: url) {
                            Label(language.text("attribution.share"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tint(AppTheme.accent)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .navigationTitle(language.text("attribution.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
