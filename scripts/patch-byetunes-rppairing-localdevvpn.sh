#!/usr/bin/env bash
set -euo pipefail

ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
DEVICE="$ROOT/iDeviceManager.swift"

test -s "$DEVICE" || { echo "missing ByeTunes iDeviceManager.swift" >&2; exit 1; }

python3 - "$DEVICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

def balanced_end(source: str, start: int) -> int:
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit("opening brace not found")
    depth = 0
    in_string = False
    escaped = False
    i = brace
    while i < len(source):
        ch = source[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit("unbalanced Swift block")

def replace_function(source: str, signature: str, replacement: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"function not found: {signature}")
    end = balanced_end(source, start)
    return source[:start] + replacement.rstrip() + "\n" + source[end:]

# LocalDevVPN/SideStore loopback transports do not guarantee that the device
# peer is 10.7.0.1. Keep Bonjour's live port, but probe the same LocalDevVPN
# peer range used by NFCARD/Airlift instead of pinning a single host.
socket_replacement = r'''    private func makeSocketAddress(port: UInt16) -> sockaddr_in {
        makeSocketAddress(host: DEVICE_HOST, port: port)
    }

    private func makeSocketAddress(host: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        host.withCString { hostCString in
            inet_pton(AF_INET, hostCString, &addr.sin_addr)
        }
        return addr
    }

    private func isRPPairingEndpointReachable(host: String, port: UInt16) -> Bool {
        host.withCString { hostCString in
            ByeTunesTCPProbe(hostCString, port, 500)
        }
    }'''
text = replace_function(
    text,
    "    private func makeSocketAddress(port: UInt16)",
    socket_replacement,
)

tunnel_replacement = r'''    private func establishRPPairingTunnel() -> Bool {
        var rpPairingPtr: RpPairingFileHandle?
        let readErr = rp_pairing_file_read(rpPairingFile.path, &rpPairingPtr)
        guard readErr == IdeviceSuccess, let rpPairingHandle = rpPairingPtr else {
            self.logOnce("[DeviceManager] ERROR: Failed to read RPPairing file. Err: \(String(describing: readErr))", key: "connection_status")
            return false
        }
        defer { rp_pairing_file_free(rpPairingHandle) }

        let discoveredPort = ByeTunesRemotePairingPortDiscovery.resolveSynchronously(timeout: 3.0)
        var ports: [UInt16] = []
        if let discoveredPort {
            ports.append(discoveredPort)
            Logger.shared.log("[DeviceManager] LocalDevVPN discovered live Remote Pairing port=\(discoveredPort)")
        } else {
            Logger.shared.log("[DeviceManager] LocalDevVPN Remote Pairing Bonjour discovery returned no port; using fallback \(RP_PAIRING_PORT)")
        }
        if !ports.contains(RP_PAIRING_PORT) {
            ports.append(RP_PAIRING_PORT)
        }

        let allowedHosts = ["10.7.0.1", "10.7.0.3", "127.0.0.1", "10.7.0.2"]
        var hosts: [String] = []
        if let cached = UserDefaults.standard.string(forKey: "filzaByeTunesLastRPPairingHost"),
           allowedHosts.contains(cached) {
            hosts.append(cached)
        }
        for host in allowedHosts where !hosts.contains(host) {
            hosts.append(host)
        }

        var lastFailure = "no reachable Remote Pairing endpoint"

        for port in ports {
            let reachableHosts = hosts.filter { host in
                isRPPairingEndpointReachable(host: host, port: port)
            }

            Logger.shared.log(
                "[DeviceManager] LocalDevVPN preflight reachable hosts=\(reachableHosts.joined(separator: ",")) port=\(port)"
            )

            guard !reachableHosts.isEmpty else {
                lastFailure = "no TCP-reachable peer on port \(port)"
                continue
            }

            for host in reachableHosts {
                resetConnectionHandles()
                var addr = makeSocketAddress(host: host, port: port)
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let tunnelErr = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        tunnel_create_rppairing(
                            sockaddrPointer,
                            addrLen,
                            "Music-Provider",
                            rpPairingHandle,
                            nil,
                            nil,
                            &rpAdapter,
                            &rpHandshake
                        )
                    }
                }

                if tunnelErr == nil, rpAdapter != nil, rpHandshake != nil {
                    UserDefaults.standard.set(host, forKey: "filzaByeTunesLastRPPairingHost")
                    Logger.shared.log("[DeviceManager] LocalDevVPN Remote Pairing connected via \(host):\(port)")
                    return true
                }

                if let err = tunnelErr {
                    let msg = err.pointee.message != nil ? String(cString: err.pointee.message!) : "No message"
                    lastFailure = "\(host):\(port) code=\(err.pointee.code) sub=\(err.pointee.sub_code) \(msg)"
                    Logger.shared.log("[DeviceManager] LocalDevVPN endpoint rejected \(host):\(port): \(msg)")
                    idevice_error_free(err)
                } else {
                    lastFailure = "\(host):\(port) returned no adapter/handshake"
                }
                resetConnectionHandles()
            }
        }

        self.logOnce(
            "[DeviceManager] ERROR: LocalDevVPN Remote Pairing unavailable. Last: \(lastFailure)",
            key: "connection_status"
        )
        return false
    }'''
text = replace_function(
    text,
    "    private func establishRPPairingTunnel()",
    tunnel_replacement,
)

# Pairing host and heartbeat transport must never compete for the old pairing
# session. ByeTunesOnDevicePairing suspends reconnect before advertising and
# resumes after the fresh RP pairing file has been persisted.
if "private var autoReconnectSuspended = false" not in text:
    anchor = "    private var autoReconnectTimer: DispatchSourceTimer?\n"
    if anchor not in text:
        raise SystemExit("autoReconnectTimer anchor missing")
    text = text.replace(
        anchor,
        anchor + "    private var autoReconnectSuspended = false\n",
        1,
    )

if "func setAutoReconnectSuspended(_ suspended: Bool)" not in text:
    anchor = "    private func installAutoReconnectWatcher() {"
    pos = text.find(anchor)
    if pos < 0:
        raise SystemExit("auto reconnect watcher missing")
    method = '''    func setAutoReconnectSuspended(_ suspended: Bool) {
        autoReconnectSuspended = suspended
        if suspended {
            Logger.shared.log("[DeviceManager] Auto-reconnect suspended for on-device pairing")
            stopHeartbeat()
        } else {
            lastHeartbeatAttemptStartedAt = .distantPast
            Logger.shared.log("[DeviceManager] Auto-reconnect resumed after on-device pairing")
        }
    }

'''
    text = text[:pos] + method + text[pos:]

watcher_replacement = r'''    private func installAutoReconnectWatcher() {
        guard autoReconnectTimer == nil else { return }

        Logger.shared.log("[DeviceManager] Installing auto-reconnect watcher")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + autoReconnectCheckInterval, repeating: autoReconnectCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard UIApplication.shared.applicationState == .active else { return }

            if self.autoReconnectSuspended {
                self.logOnce("[DeviceManager] Auto-reconnect paused while on-device pairing is active", key: "auto_reconnect")
                return
            }

            self.refreshExpectedPairingFileState()
            guard self.hasValidExpectedPairingFile else {
                self.logOnce("[DeviceManager] Auto-reconnect skipped: pairing file is not valid", key: "auto_reconnect")
                return
            }

            self.reconnectCoordinationLock.lock()
            let reconnectInFlight = self.isReconnecting
            self.reconnectCoordinationLock.unlock()
            guard !reconnectInFlight else {
                self.logOnce("[DeviceManager] Auto-reconnect skipped: connection attempt still active", key: "auto_reconnect")
                return
            }

            guard self.connectionStatus != "Connecting..." else {
                self.logOnce("[DeviceManager] Auto-reconnect skipped: waiting for current connection attempt", key: "auto_reconnect")
                return
            }

            let needsReconnect = !self.heartbeatReady || !self.hasActiveTransport
            guard needsReconnect else { return }

            let timeSinceLastAttempt = Date().timeIntervalSince(self.lastHeartbeatAttemptStartedAt)
            guard timeSinceLastAttempt >= 10.0 else { return }

            self.logOnce("[DeviceManager] Auto-reconnect retrying LocalDevVPN Remote Pairing", key: "auto_reconnect")
            self.startHeartbeat(forceReconnect: false)
        }
        timer.resume()
        autoReconnectTimer = timer
    }'''
text = replace_function(
    text,
    "    private func installAutoReconnectWatcher()",
    watcher_replacement,
)

# Keep isReconnecting held for the full establishment window so the watcher
# cannot launch a second tunnel while the first is still resolving/handshaking.
old_poll = '''        DispatchQueue.global().async {
            for _ in 0..<20 {
                if self.heartbeatReady && self.hasActiveTransport {
                    DispatchQueue.main.async { finish(true) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async { finish(false) }
        }
'''
new_poll = '''        DispatchQueue.global().async {
            for _ in 0..<48 {
                if self.heartbeatReady && self.hasActiveTransport {
                    DispatchQueue.main.async { finish(true) }
                    return
                }

                let status = self.connectionStatus
                if status == "Connection Failed" || status.hasPrefix("Invalid ") {
                    DispatchQueue.main.async { finish(false) }
                    return
                }

                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                if self.connectionStatus == "Connecting..." {
                    self.connectionStatus = "Connection Failed"
                    self.heartbeatReady = false
                }
                finish(false)
            }
        }
'''
if "for _ in 0..<48" not in text:
    count = text.count(old_poll)
    if count != 1:
        raise SystemExit(f"heartbeat completion poll: expected one match, found {count}")
    text = text.replace(old_poll, new_poll, 1)

text = text.replace(
    "    private let autoReconnectCheckInterval: TimeInterval = 2\n",
    "    private let autoReconnectCheckInterval: TimeInterval = 4\n",
    1,
)

path.write_text(text)
PY

grep -Fq 'ByeTunesRemotePairingPortDiscovery.resolveSynchronously' "$DEVICE"
grep -Fq 'LocalDevVPN discovered live Remote Pairing port=' "$DEVICE"
grep -Fq 'ByeTunesTCPProbe' "$DEVICE"
grep -Fq 'LocalDevVPN preflight reachable hosts=' "$DEVICE"
grep -Fq 'LocalDevVPN Remote Pairing connected via \(host):\(port)' "$DEVICE"
grep -Fq 'private var autoReconnectSuspended = false' "$DEVICE"
grep -Fq 'func setAutoReconnectSuspended(_ suspended: Bool)' "$DEVICE"
grep -Fq 'Auto-reconnect paused while on-device pairing is active' "$DEVICE"
grep -Fq 'for _ in 0..<48' "$DEVICE"
grep -Fq '"10.7.0.2"' "$DEVICE"
grep -Fq '"10.7.0.3"' "$DEVICE"
grep -Fq '"127.0.0.1"' "$DEVICE"

echo "Applied preflighted LocalDevVPN Remote Pairing transport"
