#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

src = Path(sys.argv[1])

library = src / "ios-app/AirCardLibrary.swift"
s = library.read_text()
s = s.replace("FilzaAirCard", "AirCard")
s = s.replace("filzaAirCard", "airCard")
s = s.replace("inside Filza 27", "in AirCard")
s = s.replace("inside Filza", "in AirCard")
library.write_text(s)

models = src / "ios-app/Models.swift"
s = models.read_text()
old = """enum AppTab: String, CaseIterable, Identifiable {
    case pairing = "Pairing"
    case walletCards = "Wallet Cards"
    case passcodeThemes = "Passcode"
    case wallpapers = "Wallpapers"
    var id: String { rawValue }
}"""
new = """enum AppTab: String, CaseIterable, Identifiable {
    case pairing = "Pairing"
    case walletCards = "Wallet Cards"
    case cardLibrary = "Library"
    var id: String { rawValue }
}"""
assert old in s, "AppTab layout changed upstream"
models.write_text(s.replace(old, new, 1))

content = src / "ios-app/ContentView.swift"
s = content.read_text()

root_start = s.index("struct ContentView: View {")
root_end_marker = "// MARK: - Pairing Tab"
root_end = s.index(root_end_marker, root_start)
assert root_start >= 0 and root_end > root_start, "Could not locate pinned ContentView root"

new_root = """struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showCardStudio = false
    @State private var lastMainTab: AppTab = .pairing

    private var airCardTabSelection: Binding<AppTab> {
        Binding(
            get: { vm.selectedTab },
            set: { newTab in
                if newTab == .cardLibrary {
                    showCardStudio = true
                    vm.selectedTab = lastMainTab
                } else {
                    lastMainTab = newTab
                    vm.selectedTab = newTab
                }
            }
        )
    }

    var body: some View {
        Group {
            if showCardStudio {
                AirCardLibraryView(onExit: {
                    showCardStudio = false
                    vm.selectedTab = lastMainTab
                })
                .environmentObject(vm)
            } else {
                TabView(selection: airCardTabSelection) {
                    NFCARDPairingTab()
                        .tabItem { Label("Pairing", systemImage: "antenna.radiowaves.left.and.right") }
                        .tag(AppTab.pairing)

                    NFCARDWalletCardsTab()
                        .tabItem { Label("Wallet Cards", systemImage: "creditcard.fill") }
                        .tag(AppTab.walletCards)

                    Color.clear
                        .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                        .tag(AppTab.cardLibrary)
                }
                .tint(NFCARDTheme.accent)
            }
        }
        .alert("Notice", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Success! 🎉", isPresented: $vm.showSuccessAlert) {
            Button("OK") {}
        } message: {
            Text(vm.successAlertMessage)
        }
        .sheet(isPresented: $vm.showShareSheet) {
            if let url = vm.exportedThemeURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
            if vm.selectedTab != .cardLibrary {
                lastMainTab = vm.selectedTab
            }
        }
    }
}

"""

s = s[:root_start] + new_root + s[root_end:]

s = s.replace(
    "Apple Wallet Skins & Passcode Themes for iOS 18+",
    "Apple Wallet card skins on iOS"
)
s = s.replace(
    "Apply custom wallet card skins and passcode themes on-device using the AirTraffic sandbox escape.",
    "Apply custom Apple Wallet card skins on-device."
)

# Remove only the Pairing-tab Credits control/sheet.
s = s.replace("    @State private var showCredits = false\n", "", 1)
pairing_credits = """            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCredits = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                            Text("Credits")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.pink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.pink.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
            .sheet(isPresented: $showCredits) {
                CreditsSheet()
            }
"""
assert pairing_credits in s, "Pairing Credits UI changed upstream"
s = s.replace(pairing_credits, "", 1)
content.write_text(s)

# Wire live Remote Pairing port discovery into the real upstream scanner.
appvm = src / "ios-app/AppViewModel.swift"
s = appvm.read_text()
s = s.replace(
    '@Published var deviceIP: String = "10.7.0.1"   // LocalDevVPN default peer\n',
    '@Published var deviceIP: String = "10.7.0.1"   // LocalDevVPN default peer\n'
    '    @Published var remotePairingPort: UInt16 = 49152\n',
    1
)

refresh_old = """    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        wifiUp = wifi
        networkDetail = detail
    }
"""
refresh_new = """    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        wifiUp = wifi
        networkDetail = detail

        RemotePairingPortDiscovery.shared.discover(timeout: 2.0) { [weak self] port in
            guard let self, let port else { return }
            self.remotePairingPort = port
            let rc = self.deviceIP.withCString { hostC in
                al_connection_endpoint_set(hostC, port)
            }
            if rc == 0 {
                self.networkDetail += " | RP=\\(self.deviceIP):\\(port)"
            }
        }
    }
"""
assert refresh_old in s, "refreshNetworkStatus changed upstream"
s = s.replace(refresh_old, refresh_new, 1)

scan_start = s.index("    func startCardScanning() {")
scan_end = s.index("    func stopCardScanning() {", scan_start)
assert scan_start >= 0 and scan_end > scan_start, "Scanner block changed upstream"
scan_new = """    func startCardScanning() {
        guard !isScanningCards else { return }
        guard hasPairingFile else {
            errorMessage = "Pairing file is required before scanning. Pair this iPhone first."
            return
        }

        scanStatusText = "Discovering this iPhone's Remote Pairing port…"
        log.append("Discovering live Remote Pairing endpoint…")

        RemotePairingPortDiscovery.shared.discover(timeout: 3.0) { [weak self] discoveredPort in
            guard let self else { return }
            let port = discoveredPort ?? self.remotePairingPort
            self.remotePairingPort = port

            let rc = self.deviceIP.withCString { hostC in
                al_connection_endpoint_set(hostC, port)
            }
            guard rc == 0 else {
                self.scanStatusText = "Scanner stopped: invalid Remote Pairing endpoint."
                self.errorMessage = "Could not configure Remote Pairing endpoint."
                return
            }

            self.log.append("Remote Pairing endpoint: \\(self.deviceIP):\\(port)")
            self.beginCardScanning()
        }
    }

    private func beginCardScanning() {
        guard !isScanningCards else { return }

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isScanningCards = true
            scanStatusText = "Open Apple Pay (double-click Side button) and tap your card…"
        }
        log.append("Started live card scanner…")

        let pairingPath = PairingController.pairingFilePath()

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>? = nil

            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(
                    pairC,
                    { _, line in
                        guard let line = line else { return }
                        let lineStr = String(cString: line)
                        let lower = lineStr.lowercased()
                        if lower.contains("pass") ||
                           lower.contains("card") ||
                           lower.contains("stockholm") ||
                           lower.contains("wallet") ||
                           lower.contains("nanopass") ||
                           lower.contains("verificationcheck") {
                            DispatchQueue.main.async {
                                AppViewModel.shared?.processSyslogLine(lineStr)
                            }
                        }
                    },
                    nil,
                    &outError
                )
            }

            let errStr = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }

            DispatchQueue.main.async {
                guard let vm = AppViewModel.shared else { return }
                vm.isScanningCards = false
                if rc != 0 {
                    let msg = errStr ?? "rc=\\(rc)"
                    vm.scanStatusText = "Scanner stopped: \\(msg)"
                    vm.log.append("❌ Scanner error: \\(msg)")
                    vm.errorMessage = "Card scanner error: \\(msg)"
                } else {
                    vm.scanStatusText = "Scanning stopped. Total cards: \\(vm.cards.count)."
                    vm.log.append("Scanning stopped. Total cards: \\(vm.cards.count).")
                }
            }
        }
        thread.name = "AirCard.SyslogScanner"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

"""
s = s[:scan_start] + scan_new + s[scan_end:]
appvm.write_text(s)

# Add discovery permission for Apple's live remote-pairing daemon.

info_path = src / "ios-app/Info.plist"
with info_path.open("rb") as fh:
    info = plistlib.load(fh)

info["CFBundleDisplayName"] = "NFCARD"
info["NSPhotoLibraryUsageDescription"] = "NFCARD needs photo access so you can choose artwork for your Wallet cards."
info["WKAppBoundDomains"] = ["cardmaker-omega.vercel.app"]
bonjour = list(info.get("NSBonjourServices", []))
if "_remotepairing._tcp" not in bonjour:
    bonjour.append("_remotepairing._tcp")
info["NSBonjourServices"] = bonjour

blocked_types = {"com.aircard.passthm", "com.aircard.tendies"}
doc_types = []
for item in info.get("CFBundleDocumentTypes", []):
    types = set(item.get("LSItemContentTypes", []))
    if not (types & blocked_types):
        doc_types.append(item)
if doc_types:
    info["CFBundleDocumentTypes"] = doc_types
else:
    info.pop("CFBundleDocumentTypes", None)

for key in ("UTImportedTypeDeclarations", "UTExportedTypeDeclarations"):
    kept = [
        item for item in info.get(key, [])
        if item.get("UTTypeIdentifier") not in blocked_types
    ]
    if kept:
        info[key] = kept
    else:
        info.pop(key, None)

with info_path.open("wb") as fh:
    plistlib.dump(info, fh, sort_keys=False)

# Patch the Rust transport to honor the live endpoint discovered by Swift,
# while preserving upstream's existing 49152 fallbacks.
exploit = src / "rust-core/src/exploit.rs"
s = exploit.read_text()
s = s.replace(
    "use std::io::{self, Write};\n",
    "use std::io::{self, Write};\nuse std::sync::{Mutex, OnceLock};\n",
    1
)
s = s.replace(
    "const RSD_PORT: u16 = 49152;\n",
    """const RSD_PORT: u16 = 49152;

static CONNECTION_ENDPOINT: OnceLock<Mutex<Option<(String, u16)>>> = OnceLock::new();

pub fn set_connection_endpoint(host: String, port: u16) -> Result<(), String> {
    if host.parse::<std::net::IpAddr>().is_err() {
        return Err("connection host must be a numeric IP address".to_string());
    }
    if port == 0 {
        return Err("connection port must be non-zero".to_string());
    }
    let slot = CONNECTION_ENDPOINT.get_or_init(|| Mutex::new(None));
    *slot.lock().map_err(|_| "connection endpoint lock poisoned".to_string())? = Some((host, port));
    Ok(())
}

fn configured_connection_endpoint() -> Option<(String, u16)> {
    CONNECTION_ENDPOINT
        .get()
        .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone()))
}
""",
    1
)

old_targets = """        let rsd_targets = [
            ("127.0.0.1", RSD_PORT),
            ("10.7.0.1", RSD_PORT),
            ("10.7.0.2", RSD_PORT),
            ("10.7.0.3", RSD_PORT),
        ];

        for (ip_str, port) in &rsd_targets {
            let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else { continue };
            let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), *port);
"""
new_targets = """        let mut rsd_targets: Vec<(String, u16)> = Vec::new();
        if let Some(endpoint) = configured_connection_endpoint() {
            logger.log(format!("airlift: using discovered Remote Pairing endpoint {}:{}", endpoint.0, endpoint.1));
            rsd_targets.push(endpoint);
        }
        for fallback in [
            ("127.0.0.1".to_string(), RSD_PORT),
            ("10.7.0.1".to_string(), RSD_PORT),
            ("10.7.0.2".to_string(), RSD_PORT),
            ("10.7.0.3".to_string(), RSD_PORT),
        ] {
            if !rsd_targets.contains(&fallback) {
                rsd_targets.push(fallback);
            }
        }

        for (ip_str, port) in &rsd_targets {
            let Ok(ip) = ip_str.parse::<std::net::IpAddr>() else { continue };
            let socket_addr = std::net::SocketAddr::new(ip, *port);
"""
assert old_targets in s, "RSD target block changed upstream"
s = s.replace(old_targets, new_targets, 1)
exploit.write_text(s)

lib = src / "rust-core/src/lib.rs"
s = lib.read_text()
insert_at = s.index("// ---------------------------------------------------------------------------\n// Exploit")
setter = """// ---------------------------------------------------------------------------
// Runtime connection endpoint
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn al_connection_endpoint_set(host: *const c_char, port: u16) -> i32 {
    let host = ffi_util::opt_str(host, "");
    match exploit::set_connection_endpoint(host, port) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

"""
s = s[:insert_at] + setter + s[insert_at:]
lib.write_text(s)

header = src / "rust-core/include/airlift.h"
s = header.read_text()
needle = "// ---------------------------------------------------------------------------\n// Exploit\n"
setter_decl = """// Configure the live Remote Pairing/RSD endpoint discovered via Bonjour.
// The endpoint is tried before upstream's historical 49152 fallbacks.
int32_t al_connection_endpoint_set(const char *host, uint16_t port);

"""
assert needle in s, "airlift.h exploit marker changed upstream"
s = s.replace(needle, setter_decl + needle, 1)
header.write_text(s)

project = src / "project.yml"
s = project.read_text()
s = s.replace(
    "PRODUCT_BUNDLE_IDENTIFIER: com.mak5er.aircard",
    "PRODUCT_BUNDLE_IDENTIFIER: com.nightvibes33.aircard"
)
project.write_text(s)


# Rebrand the visible on-device pairing host while preserving pairing behavior.
pairing_controller = src / "ios-app/PairingController.swift"
s = pairing_controller.read_text()
s = s.replace('private let hostName = "AirCard-iOS"', 'private let hostName = "NFCARD"')
s = s.replace("Settings › AirCard-iOS › Local Network", "Settings › NFCARD › Local Network")
s = s.replace("Pair with AirCard-iOS", "Pair with NFCARD")
pairing_controller.write_text(s)
