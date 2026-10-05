import Foundation
import Combine
import AVFoundation
import AirliftFFI

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
            Logger.shared.log("[PairingHost] background keepalive started")
        } catch {
            running = false
            Logger.shared.log("[PairingHost] background keepalive unavailable: \(error.localizedDescription)")
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
        Logger.shared.log("[PairingHost] background keepalive stopped")
    }
}

@MainActor
final class ByeTunesOnDevicePairingController: ObservableObject {
    static let shared = ByeTunesOnDevicePairingController()

    @Published private(set) var isPairing = false
    @Published private(set) var status = "Ready"
    @Published private(set) var pin: String?

    private let keepAlive = ByeTunesPairingKeepAlive()
    private var netService: NetService?

    private static let altIRKKey = "filzaByeTunesPairingHostAltIRK"

    private init() {}

    func start(manager: DeviceManager) {
        guard !isPairing else { return }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 27 else {
            status = "On-device pairing requires iOS 27 or newer."
            return
        }

        stopAdvertising()
        manager.setAutoReconnectSuspended(true)
        isPairing = true
        pin = nil
        status = "Advertising ByeTunes… Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes"
        keepAlive.start()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("byetunes-rp-pairing-\(UUID().uuidString).plist")
        try? FileManager.default.removeItem(at: outputURL)

        let altIRK = UserDefaults.standard.string(forKey: Self.altIRKKey) ?? ""
        nonisolated(unsafe) let context = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = "0.0.0.0".withCString { bindC in
                "ByeTunes".withCString { nameC in
                    "Mac17,7".withCString { modelC in
                        outputURL.path.withCString { outputC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC,
                                    0,
                                    nameC,
                                    modelC,
                                    outputC,
                                    irkC,
                                    byeTunesAirliftReadyCallback,
                                    byeTunesAirliftPinCallback,
                                    context,
                                    &result
                                )
                            }
                        }
                    }
                }
            }

            let errorMessage = result.error.map { String(cString: $0) }
            let producedPath = result.pairing_file_path.map { String(cString: $0) } ?? outputURL.path
            let issuedAltIRK = result.host_alt_irk_hex.map { String(cString: $0) } ?? ""
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<ByeTunesOnDevicePairingController>
                    .fromOpaque(context)
                    .release()

                self.stopAdvertising()

                guard rc == 0 else {
                    manager.setAutoReconnectSuspended(false)
                    self.finishFailure(errorMessage ?? "Pairing failed (rc=\(rc)).")
                    return
                }

                if !issuedAltIRK.isEmpty {
                    UserDefaults.standard.set(issuedAltIRK, forKey: Self.altIRKKey)
                }

                let producedURL = URL(fileURLWithPath: producedPath)
                do {
                    try manager.importPairingFile(from: producedURL)
                    try? FileManager.default.removeItem(at: producedURL)
                    manager.refreshExpectedPairingFileState()

                    guard manager.hasValidExpectedPairingFile else {
                        manager.setAutoReconnectSuspended(false)
                        self.finishFailure("ByeTunes created a pairing record, but it did not validate.")
                        return
                    }

                    self.status = "Paired. Connecting through LocalDevVPN…"
                    self.pin = nil
                    self.isPairing = false
                    Logger.shared.log("[PairingHost] ByeTunes on-device RP pairing completed")
                    manager.setAutoReconnectSuspended(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        manager.startHeartbeat(forceReconnect: true)
                    }
                    self.stopKeepAliveSoon()
                } catch {
                    try? FileManager.default.removeItem(at: producedURL)
                    manager.setAutoReconnectSuspended(false)
                    self.finishFailure(error.localizedDescription)
                }
            }
        }
    }

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        status = "Open Settings › Privacy & Security › Developer Mode › Pair with ByeTunes"
        Logger.shared.log("[PairingHost] advertised ByeTunes pairable host port=\(port)")
    }

    fileprivate func receivePIN(_ value: String) {
        pin = value
        status = "Enter PIN \(value) in Settings › Privacy & Security › Developer Mode › Pair with ByeTunes"
        Logger.shared.log("[PairingHost] ByeTunes PIN ready")
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    private func finishFailure(_ message: String) {
        stopAdvertising()
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
}

private let byeTunesAirliftReadyCallback: ALPairReadyCb = {
    context, serviceID, port, keys, values, count in

    guard let context, let serviceID else { return }
    let controller = Unmanaged<ByeTunesOnDevicePairingController>
        .fromOpaque(context)
        .takeUnretainedValue()

    var txt: [String: Data] = [:]
    if let keys, let values {
        for index in 0..<Int(count) {
            guard let key = keys[index], let value = values[index] else { continue }
            txt[String(cString: key)] = Data(String(cString: value).utf8)
        }
    }

    let identifier = String(cString: serviceID)
    DispatchQueue.main.async {
        controller.startAdvertising(
            serviceID: identifier,
            port: Int32(port),
            txt: txt
        )
    }
}

private let byeTunesAirliftPinCallback: ALPairPinCb = { pinPointer, context in
    guard let pinPointer, let context else { return }
    let controller = Unmanaged<ByeTunesOnDevicePairingController>
        .fromOpaque(context)
        .takeUnretainedValue()
    let value = String(cString: pinPointer)

    DispatchQueue.main.async {
        controller.receivePIN(value)
    }
}
