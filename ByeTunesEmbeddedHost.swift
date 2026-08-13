import SwiftUI
import UIKit

private final class ByeTunesEmbeddedNavigationController: UINavigationController {
    @objc func closeEmbeddedByeTunes() {
        dismiss(animated: true)
    }
}

private final class ByeTunesDeferredHostController: UIViewController {
    private var hasStarted = false
    private var hostedController: UIViewController?
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        FilzaDiagnosticsWriteByeTunesStage("deferred Swift host UIKit shell viewDidLoad")
        view.backgroundColor = .systemGroupedBackground

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Starting ByeTunes…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startEmbeddedContentIfNeeded()
    }

    @objc(startEmbeddedContentIfNeeded)
    func startEmbeddedContentIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        FilzaDiagnosticsWriteByeTunesStage("complete ByeTunes ContentView startup scheduled")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            FilzaDiagnosticsWriteByeTunesStage("before ContentView construction")
            let root = ContentView()
            FilzaDiagnosticsWriteByeTunesStage("ContentView constructed")

            let host = UIHostingController(rootView: root)
            FilzaDiagnosticsWriteByeTunesStage("UIHostingController constructed")
            host.view.backgroundColor = .systemGroupedBackground

            self.addChild(host)
            FilzaDiagnosticsWriteByeTunesStage("before ByeTunes Swift host view materialization")
            let hostedView = host.view!
            FilzaDiagnosticsWriteByeTunesStage("ByeTunes Swift host view materialized")
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(hostedView)
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: self.view.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            host.didMove(toParent: self)
            self.hostedController = host
            self.statusLabel.removeFromSuperview()
            FilzaDiagnosticsWriteByeTunesStage("ByeTunes Swift host attached successfully")
        }
    }
}

/// Hosts the complete ByeTunes application inside Filza without constructing
/// ContentView inside the Objective-C factory call. The UIKit shell is attached
/// first; ContentView and DeviceManager.shared are entered only after the shell
/// reaches viewDidAppear, with a persistent breadcrumb at every boundary.
@objc(ByeTunesEmbeddedHostFactory)
public final class ByeTunesEmbeddedHostFactory: NSObject {
    @objc(makeLibraryViewController)
    public static func makeLibraryViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("Swift ByeTunes factory entered")
        let controller = ByeTunesDeferredHostController()
        FilzaDiagnosticsWriteByeTunesStage("Swift ByeTunes factory returned deferred UIKit host")
        return controller
    }

    @objc(makeViewController)
    public static func makeViewController() -> UIViewController {
        FilzaDiagnosticsWriteByeTunesStage("standalone ByeTunes factory entered")
        let deferred = ByeTunesDeferredHostController()
        deferred.title = "ByeTunes"
        let navigation = ByeTunesEmbeddedNavigationController(rootViewController: deferred)
        deferred.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: navigation,
            action: #selector(ByeTunesEmbeddedNavigationController.closeEmbeddedByeTunes)
        )
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }
}
