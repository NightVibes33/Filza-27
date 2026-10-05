import Foundation
import Combine
import AVFoundation

@MainActor
private final class ByeTunesPairingKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player.engine == nil {
                engine.attach(player)
            }

            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                running = true
                return
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)
            let frames = max(1024, AVAudioFrameCount(format.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                running = true
                return
            }

            buffer.frameLength = frames
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
            Logger.shared.log("[PairingHost] Background keepalive started")
        } catch {
            running = false
            Logger.shared.log("[PairingHost] Background keepalive unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if player.engine != nil {
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        Logger.shared.log("[PairingHost] Background keepalive stopped")
    }
}

@MainActor
final class ByeTunesOnDevicePairingController: ObservableObject {
    static let shared = ByeTunesOnDevicePairingController()

    @Published private(set) var isPairing = false
    @Published private(set) var status = "Ready"
    @Published private(set) var pin: String?

    private let keepAlive = ByeTunesPairingKeepAlive()

    private init() {}

    func start(manager: DeviceManager) {
        guard !isPairing else { return }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 27 else {
            status = "On-device pairing requires iOS 27 or newer."
            return
        }

        isPairing = true
        pin = nil
        status = "Advertising ByeTunes… Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes"
        keepAlive.start()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("byetunes-rp-pairing-\(UUID().uuidString).plist")
        try? FileManager.default.removeItem(at: outputURL)

        nonisolated(unsafe) let context = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var pairingHandle: RpPairingFileHandle?
            let err = "ByeTunes".withCString { nameC in
                "Mac17,7".withCString { modelC in
                    pairable_host_accept(
                        nameC,
                        modelC,
                        0,
                        byeTunesPairingPinCallback,
                        context,
                        nil,
                        &pairingHandle
                    )
                }
            }

            var errorMessage: String?
            if let err {
                let message = err.pointee.message != nil
                    ? String(cString: err.pointee.message!)
                    : "Unknown pairing error"
                errorMessage = "Pairing failed (\(err.pointee.code)/\(err.pointee.sub_code)): \(message)"
                idevice_error_free(err)
            }

            var writeError: String?
            if errorMessage == nil {
                guard let pairingHandle else {
                    DispatchQueue.main.async {
                        Unmanaged<ByeTunesOnDevicePairingController>
                            .fromOpaque(context)
                            .release()
                        self.finishFailure("Pairing completed without a pairing record.")
                    }
                    return
                }

                let writeResult = outputURL.path.withCString { pathC in
                    rp_pairing_file_write(pairingHandle, pathC)
                }
                rp_pairing_file_free(pairingHandle)

                if let writeResult {
                    let message = writeResult.pointee.message != nil
                        ? String(cString: writeResult.pointee.message!)
                        : "Unknown pairing-file error"
                    writeError = "Could not save pairing record (\(writeResult.pointee.code)/\(writeResult.pointee.sub_code)): \(message)"
                    idevice_error_free(writeResult)
                }
            }

            DispatchQueue.main.async {
                Unmanaged<ByeTunesOnDevicePairingController>
                    .fromOpaque(context)
                    .release()

                if let errorMessage {
                    self.finishFailure(errorMessage)
                    return
                }
                if let writeError {
                    self.finishFailure(writeError)
                    return
                }

                do {
                    try manager.importPairingFile(from: outputURL)
                    try? FileManager.default.removeItem(at: outputURL)
                    manager.refreshExpectedPairingFileState()

                    guard manager.hasValidExpectedPairingFile else {
                        self.finishFailure("ByeTunes created a pairing record, but it did not validate.")
                        return
                    }

                    self.status = "Paired. Connecting through LocalDevVPN…"
                    self.pin = nil
                    self.isPairing = false
                    Logger.shared.log("[PairingHost] On-device RP pairing completed; starting LocalDevVPN Remote Pairing")
                    manager.startHeartbeat(forceReconnect: true)
                    self.stopKeepAliveSoon()
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.finishFailure(error.localizedDescription)
                }
            }
        }
    }

    private func receivePIN(_ value: String) {
        pin = value
        status = "Enter PIN \(value) in Settings › Privacy & Security › Developer Mode › Pair with ByeTunes"
        Logger.shared.log("[PairingHost] PIN ready; approve Pair with ByeTunes in Developer Mode")
    }

    private func finishFailure(_ message: String) {
        isPairing = false
        pin = nil
        status = message
        Logger.shared.log("[PairingHost] ERROR: \(message)")
        stopKeepAliveSoon()
    }

    private func stopKeepAliveSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.keepAlive.stop()
        }
    }

    fileprivate nonisolated static func deliverPIN(_ value: String, context: UnsafeMutableRawPointer) {
        let controller = Unmanaged<ByeTunesOnDevicePairingController>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            controller.receivePIN(value)
        }
    }
}

private let byeTunesPairingPinCallback: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pinPointer, context in
    guard let pinPointer, let context else { return }
    let value = String(cString: pinPointer)
    ByeTunesOnDevicePairingController.deliverPIN(value, context: context)
}
