import Foundation
import Darwin

private final class ByeTunesRemotePairingPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?

    func set(_ port: UInt16?) {
        lock.lock()
        value = port
        lock.unlock()
    }

    func get() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Exact LocalDevVPN Remote Pairing discovery model used by the working
/// temp AirCard/NFCARD branch: passively resolve Apple's live
/// _remotepairing._tcp Bonjour service and use that advertised port.
final class ByeTunesRemotePairingPortDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = ByeTunesRemotePairingPortDiscovery()

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var completion: ((UInt16?) -> Void)?
    private var fallbackPort: UInt16?
    private var generation = 0

    func discover(timeout: TimeInterval = 3.0, completion: @escaping (UInt16?) -> Void) {
        finish(nil)
        generation &+= 1
        let currentGeneration = generation
        self.completion = completion
        fallbackPort = nil
        services.removeAll()

        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == currentGeneration, self.completion != nil else { return }
            self.finish(self.fallbackPort)
        }
    }

    func stop() {
        finish(nil)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 1.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, sender.port <= Int(UInt16.max) else { return }
        let port = UInt16(sender.port)
        if fallbackPort == nil {
            fallbackPort = port
        }

        let ownWiFi = NetworkStatus.interfaces().first(where: { $0.name == "en0" })?.ipv4
        let resolved = (sender.addresses ?? []).compactMap(Self.ipv4Address)

        if let ownWiFi, resolved.contains(ownWiFi) {
            finish(port)
            return
        }

        // This is the behavior used by the working AirCard temp branch for
        // loopback-only LocalDevVPN setups: if there is only one live RP
        // service, trust its advertised port instead of assuming 49152.
        if services.count == 1 {
            finish(port)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // Keep waiting for another result until timeout.
    }

    private func finish(_ port: UInt16?) {
        browser?.stop()
        browser?.delegate = nil
        browser = nil

        for service in services {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()

        guard let completion else { return }
        self.completion = nil
        let value = port ?? fallbackPort
        fallbackPort = nil
        completion(value)
    }

    private static func ipv4Address(_ data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            let sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
            var addr = sin.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }

    static func resolveSynchronously(timeout: TimeInterval = 3.0) -> UInt16? {
        guard !Thread.isMainThread else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ByeTunesRemotePairingPortBox()

        DispatchQueue.main.async {
            shared.discover(timeout: timeout) { port in
                box.set(port)
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout + 1.0)
        return box.get()
    }
}
