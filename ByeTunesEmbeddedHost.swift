import SwiftUI
import UIKit

/// One-time repair for preference state written by older Filza compatibility
/// builds. Those builds could leave metadataSourcesJSON inconsistent with the
/// visible metadataSource picker. Reconcile that known contamination once,
/// then leave the original ByeTunes state machine completely in control.
private enum ByeTunesEmbeddedStateRepair {
    private static let completedKey = "filzaByeTunesMetadataParityStateRepairV1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return }

        let selected = (defaults.string(forKey: MetadataProviderSettings.legacySourceKey) ?? "local").lowercased()
        let repaired: [MetadataProviderID]
        switch selected {
        case "youtube":
            repaired = [.local, .youtube]
        case "itunes":
            repaired = [.itunes]
        case "deezer":
            repaired = [.deezer]
        case "apple":
            repaired = [.apple]
        case "all":
            repaired = MetadataProviderSettings.defaultSources
        default:
            repaired = [.local]
        }

        MetadataProviderSettings.saveSources(repaired)
        defaults.set(true, forKey: completedKey)
        Logger.shared.log(
            "[MetadataParity] Reconciled legacy embedded provider state once: picker=\(selected), sources=\(repaired.map(\.rawValue).joined(separator: ","))"
        )
    }
}

/// The standalone ByeTunes app renders ContentView directly from WindowGroup.
/// Keep the embedded full-screen route geometrically equivalent: no extra
/// UINavigationController, navigation title, or safe-area shift. Filza still
/// needs an escape hatch from a presented full-screen controller, so the close
/// control is overlaid without participating in ContentView layout.
private struct ByeTunesEmbeddedModalRoot: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                ContentView()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .padding(.top, max(proxy.safeAreaInsets.top + 6, 10))
                .padding(.trailing, 12)
                .zIndex(1000)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private func makeMusicLibraryHost() -> UIViewController {
    FilzaDiagnosticsWriteByeTunesStage("before direct Music Library ContentView construction")
    ByeTunesEmbeddedStateRepair.runIfNeeded()
    let root = ContentView()
    FilzaDiagnosticsWriteByeTunesStage("direct Music Library ContentView constructed")
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .systemGroupedBackground
    FilzaDiagnosticsWriteByeTunesStage("direct Music Library SwiftUI host ready")
    return host
}

private func makePresentedMusicLibraryHost() -> UIViewController {
    FilzaDiagnosticsWriteByeTunesStage("before parity-preserving presented Music Library host construction")
    ByeTunesEmbeddedStateRepair.runIfNeeded()
    let host = UIHostingController(rootView: ByeTunesEmbeddedModalRoot())
    host.view.backgroundColor = .systemGroupedBackground
    host.modalPresentationStyle = .fullScreen
    FilzaDiagnosticsWriteByeTunesStage("parity-preserving full-screen Music Library host ready")
    return host
}

@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
    @objc(handleBackgroundEventsForSessionIdentifier:completionHandler:)
    public static func handleBackgroundEvents(
        forSessionIdentifier identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        if identifier == MetadataBackgroundURLSession.sessionIdentifier {
            guard BackgroundMetadataFetchManager.isEnabled else {
                completionHandler()
                return true
            }
            MetadataBackgroundURLSession.shared.setBackgroundEventsCompletionHandler(completionHandler)
            BackgroundMetadataFetchManager.shared.processPendingDownloadsInBackground()
            return true
        }

        guard identifier == BackgroundAudioDownloadManager.sessionIdentifier else {
            return false
        }
        guard UserDefaults.standard.bool(forKey: "backgroundDownloadsEnabled") else {
            completionHandler()
            return true
        }
        BackgroundAudioDownloadManager.shared.setBackgroundEventsCompletionHandler(completionHandler)
        return true
    }

    /// Used when Filza's existing Music Library controller owns navigation.
    /// This is a raw upstream ContentView host with no extra container UI.
    @objc(makeLibraryViewController)
    public static func makeLibraryViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("direct Music Library factory entered")
        return makeMusicLibraryHost()
    }

    /// Used by the direct full-screen fallback route. The close affordance is
    /// an overlay, not a UINavigationController, so it does not move or resize
    /// the original ByeTunes content hierarchy.
    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("standalone Music Library factory entered")
        return makePresentedMusicLibraryHost()
    }
}
