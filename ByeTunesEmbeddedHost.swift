import SwiftUI
import UIKit

/// One-time repair for preference state written by older Filza compatibility
/// builds. Those builds could leave metadataSourcesJSON inconsistent with the
/// visible metadataSource picker. Reconcile that known contamination once,
/// then leave the original ByeTunes state machine completely in control.
private enum ByeTunesEmbeddedStateRepair {
    private static let completedKey = "filzaByeTunesMetadataParityStateRepairV2"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return }

        // Older embedded builds could create metadataSource before ByeTunes'
        // @AppStorage default was materialized. Treat a missing/invalid value as
        // upstream ByeTunes 2.5's default ("apple"), never as Filza-local.
        let stored = defaults.string(forKey: MetadataProviderSettings.legacySourceKey)?.lowercased()
        let selected: String
        let repaired: [MetadataProviderID]
        switch stored {
        case "youtube":
            selected = "youtube"
            repaired = [.local, .youtube]
        case "itunes":
            selected = "itunes"
            repaired = [.itunes]
        case "deezer":
            selected = "deezer"
            repaired = [.deezer]
        case "apple":
            selected = "apple"
            repaired = [.apple]
        case "all":
            selected = "all"
            repaired = MetadataProviderSettings.defaultSources
        default:
            selected = "apple"
            repaired = [.apple]
            defaults.set(selected, forKey: MetadataProviderSettings.legacySourceKey)
        }

        // Preserve ByeTunes 2.5's own downloader default on clean installs.
        if defaults.string(forKey: "downloadSearchProvider") == nil {
            defaults.set("deezer", forKey: "downloadSearchProvider")
        }

        MetadataProviderSettings.saveSources(repaired)
        defaults.set(true, forKey: completedKey)
        Logger.shared.log(
            "[MetadataParity] Reconciled legacy embedded provider state once: picker=\(selected), sources=\(repaired.map(\.rawValue).joined(separator: ","))"
        )
    }
}

/// Standalone/presented ByeTunes uses the exact same embedded-app chrome as
/// 3105: persistent material Close bar, divider, large page sheet and grabber.
/// ByeTunes' own ContentView stays unchanged inside that shell.
private struct ByeTunesEmbeddedModalRoot: View {
    var body: some View {
        FilzaEmbeddedPanel {
            ContentView()
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
    FilzaDiagnosticsWriteByeTunesStage("before 3105-style presented Music Library host construction")
    ByeTunesEmbeddedStateRepair.runIfNeeded()
    let host = UIHostingController(rootView: ByeTunesEmbeddedModalRoot())
    host.view.backgroundColor = .systemGroupedBackground
    FilzaEmbeddedPanelPresentation.configure(host)
    FilzaDiagnosticsWriteByeTunesStage("3105-style page-sheet Music Library host ready")
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
    /// This remains a raw upstream ContentView host to avoid nesting a second
    /// modal shell inside a Filza-owned container.
    @objc(makeLibraryViewController)
    public static func makeLibraryViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("direct Music Library factory entered")
        return makeMusicLibraryHost()
    }

    /// Used by the direct presented route. This now uses exactly the same
    /// embedded page-sheet/Close-bar presentation contract as 3105.
    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("standalone Music Library factory entered")
        return makePresentedMusicLibraryHost()
    }
}
