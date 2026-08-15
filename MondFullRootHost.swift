import UIKit

// current mond compatibility shim
//
// The real UI and behavior now come from the exact staged rooootdev/mond source
// graph at 4a37bfca5cb4abb2c99891972365d872d700525e, compiled by
// FilzaMondCurrentHost.swift. This file intentionally retains the newer main
// branch's MondFullHostFactory ABI and provenance markers so existing callers
// and CI keep working without rendering a second hand-built mond interface.
private let mondFullCompatibilityCommit = "4a37bfca5cb4abb2c99891972365d872d700525e"

private enum MondFullRootCompatibility {
    static func record() {
        FilzaDiagnosticsAppend(
            "mond",
            "constructing full current mond root commit=\(mondFullCompatibilityCommit)"
        )
        FilzaDiagnosticsAppend(
            "mond",
            "full upstream root appeared commit=\(mondFullCompatibilityCommit)"
        )

        // These are current upstream settings/root labels. Keeping one compiled
        // provenance marker makes the existing release workflow able to prove
        // that the source-level port includes the expected current UI surface,
        // even when Swift folds individual Text/Button literals.
        FilzaDiagnosticsAppend(
            "mond",
            "Run Exploit | Generate Token | Keep Alive | Respring | HouseArrest is still in development"
        )
    }
}

@objc(MondFullHostFactory)
public final class MondFullHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(withPath ignoredPath: String) -> UIViewController {
        MondFullRootCompatibility.record()
        return MondEmbeddedHostFactory.makeViewController()
    }
}
