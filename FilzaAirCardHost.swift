import Foundation
import SwiftUI
import UIKit
import AirliftFFI

private enum AirCardEmbeddedRuntime {
    static var configured = false
    @MainActor static func configureOnce() {
        guard !configured else { return }; configured = true
        al_log_init({ _, msg in
            guard let msg else { return }
            let line = String(cString: msg)
            DispatchQueue.main.async { AppViewModel.sharedLogSink?(line) }
        }, nil)
        _ = ALGetGrappaToken(0,0,0,nil,0,nil,nil,0)
    }
}
@_silgen_name("ALGetGrappaToken")
private func ALGetGrappaToken(_ a: UInt32,_ b: UInt32,_ c: UInt32,_ d: UnsafeMutablePointer<UInt8>?,_ e: Int,_ f: UnsafeMutablePointer<Int>?,_ g: UnsafeMutablePointer<CChar>?,_ h: Int)->Int32
private struct AirCardEmbeddedRoot: View {
    @StateObject private var vm = AppViewModel()
    var body: some View { ContentView().environmentObject(vm).task { _ = await LocalNetworkAuthorization().request(timeout: 2.5) } }
}
@MainActor @objc(AirCardEmbeddedHostFactory)
public final class AirCardEmbeddedHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        AirCardEmbeddedRuntime.configureOnce()
        let c=UIHostingController(rootView: AirCardEmbeddedRoot()); c.modalPresentationStyle = .fullScreen; c.title="AirCard"; return c
    }
}
