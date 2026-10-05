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

# LocalDevVPN/SideStore loopback setups do not guarantee that Remote Pairing
# is reachable specifically through 10.7.0.1. NFCARD already probes the three
# LocalDevVPN peers; use the same contract here while retaining Bonjour's live
# port when iOS advertises one.
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
    }'''
if "private func makeSocketAddress(host: String, port: UInt16)" not in text:
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

        let discoveredPort = RemotePairingDiscovery.resolvePort()
        var ports: [UInt16] = []
        if let discoveredPort {
            ports.append(discoveredPort)
            if discoveredPort != RP_PAIRING_PORT {
                Logger.shared.log("[DeviceManager] Remote Pairing Bonjour port=\(discoveredPort)")
            }
        }
        if !ports.contains(RP_PAIRING_PORT) {
            ports.append(RP_PAIRING_PORT)
        }

        let hosts = ["10.7.0.1", "10.7.0.2", "10.7.0.3", "127.0.0.1"]
        var lastFailure = "no endpoint attempted"

        for port in ports {
            for host in hosts {
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
                    Logger.shared.log("[DeviceManager] LocalDevVPN Remote Pairing connected via \(host):\(port)")
                    return true
                }

                if let err = tunnelErr {
                    let msg = err.pointee.message != nil ? String(cString: err.pointee.message!) : "No message"
                    lastFailure = "\(host):\(port) code=\(err.pointee.code) sub=\(err.pointee.sub_code) \(msg)"
                    idevice_error_free(err)
                } else {
                    lastFailure = "\(host):\(port) returned no adapter/handshake"
                }
                resetConnectionHandles()
            }
        }

        self.logOnce(
            "[DeviceManager] ERROR: Remote Pairing unavailable across LocalDevVPN endpoints. Last: \(lastFailure)",
            key: "connection_status"
        )
        return false
    }'''
if "LocalDevVPN Remote Pairing connected via" not in text:
    text = replace_function(
        text,
        "    private func establishRPPairingTunnel()",
        tunnel_replacement,
    )

# Never overlap a still-live RPPairing attempt. The old 2-second watcher
# declared Connecting stale after 6 seconds even though the heartbeat worker
# is allowed 20 seconds, creating multiple competing tunnels after a reset.
watcher_replacement = r'''    private func installAutoReconnectWatcher() {
        guard autoReconnectTimer == nil else { return }

        Logger.shared.log("[DeviceManager] Installing auto-reconnect watcher")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + autoReconnectCheckInterval, repeating: autoReconnectCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard UIApplication.shared.applicationState == .active else { return }

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

            self.logOnce("[DeviceManager] Auto-reconnect retrying Remote Pairing", key: "auto_reconnect")
            self.startHeartbeat(forceReconnect: false)
        }
        timer.resume()
        autoReconnectTimer = timer
    }'''
if "Auto-reconnect retrying Remote Pairing" not in text:
    text = replace_function(
        text,
        "    private func installAutoReconnectWatcher()",
        watcher_replacement,
    )

# Keep isReconnecting held for at least as long as the heartbeat worker's
# 20-second establishment timeout. Also finish early when the worker explicitly
# reports failure instead of leaving the UI stuck in Connecting.
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

# Slow the watcher slightly; endpoint probing is now deliberate rather than a
# 2-second busy loop.
text = text.replace(
    "    private let autoReconnectCheckInterval: TimeInterval = 2\n",
    "    private let autoReconnectCheckInterval: TimeInterval = 4\n",
    1,
)

path.write_text(text)
PY

grep -Fq 'private func makeSocketAddress(host: String, port: UInt16)' "$DEVICE"
grep -Fq '"10.7.0.2"' "$DEVICE"
grep -Fq '"10.7.0.3"' "$DEVICE"
grep -Fq 'LocalDevVPN Remote Pairing connected via' "$DEVICE"
grep -Fq 'Auto-reconnect retrying Remote Pairing' "$DEVICE"
grep -Fq 'connection attempt still active' "$DEVICE"
grep -Fq 'for _ in 0..<48' "$DEVICE"
! grep -Fq 'Auto-reconnect detected stale connecting state; forcing refresh' "$DEVICE"

echo "Applied LocalDevVPN Remote Pairing endpoint/backoff repair"
