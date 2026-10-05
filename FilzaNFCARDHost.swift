import Foundation
import SwiftUI
import UIKit
import AirliftFFI

private enum NFCARDEmbeddedRuntime {
    static var configured = false

    @MainActor
    static func configureOnce() {
        guard !configured else { return }
        configured = true

        _ = al_log_init({ _, message in
            guard let message else { return }
            let line = String(cString: message)
            FilzaDiagnosticsAppend("NFCARD", line)
        }, nil)

        FilzaDiagnosticsAppend(
            "NFCARD",
            "embedded NFCARD runtime configured pin=4dbacf6b503d861dba605286f9ee6f7904c8a81f"
        )
    }
}

private struct NFCARDEmbeddedRoot: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        FilzaEmbeddedPanel {
            NFCARDContentView()
                .environmentObject(vm)
                .task {
                    _ = await LocalNetworkAuthorization().request(timeout: 2.5)
                }
        }
    }
}

@MainActor
@objc(NFCARDEmbeddedHostFactory)
public final class NFCARDEmbeddedHostFactory: NSObject {
    @objc
    public static func makeViewController() -> UIViewController {
        NFCARDEmbeddedRuntime.configureOnce()

        let controller = UIHostingController(rootView: NFCARDEmbeddedRoot())
        controller.title = "NFCARD"
        FilzaEmbeddedPanelPresentation.configure(controller)
        return controller
    }
}
