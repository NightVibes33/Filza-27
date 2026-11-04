#!/usr/bin/env python3
"""Use Filza's validated RP record from NFCARD and hide NFCARD's pairing tab.

NFCARD's pairing implementation remains compiled so existing on-device host
operations are not removed. The only visible setup is Filza main Settings >
Device Pairing; its validated DeviceManager record is consulted first.
"""
from pathlib import Path

def replace_once(path: Path, old: str, new: str, marker: str):
    s = path.read_text(encoding="utf-8")
    if marker in s:
        return
    if s.count(old) != 1:
        raise SystemExit(f"NFCARD unified pairing anchor changed: {path}: {old[:70]} ({s.count(old)})")
    s = s.replace(old, new, 1)
    path.write_text(s, encoding="utf-8")

root = Path("ThirdParty/NFCARD/ios-app")
view = root / "NFCARDContentView.swift"
replace_once(view, "    @State private var lastMainTab: AppTab = .pairing",
    "    // FILZA_UNIFIED_NFCARD_PAIRING: NFCARD's visible pairing tab moved to Filza Settings.\n"
    "    @State private var lastMainTab: AppTab = .walletCards",
    "FILZA_UNIFIED_NFCARD_PAIRING")
view_src = view.read_text(encoding="utf-8")
old_tab = '''                NFCARDPairingTab()
                    .tabItem { Label("Pairing", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(AppTab.pairing)

'''
if old_tab in view_src:
    assert view_src.count(old_tab) == 1
    view.write_text(view_src.replace(old_tab, "", 1), encoding="utf-8")
elif "NFCARDPairingTab()" in view_src:
    raise SystemExit("NFCARD pairing tab changed upstream")

# The marker above intentionally isn't present after deletion. Verify through
# the idempotent absence check rather than expecting a surviving marker.
vm = root / "AppViewModel.swift"
replace_once(vm,
    "    @Published var selectedTab: AppTab = .pairing",
    "    // FILZA_NFCARD_DEFAULT_WALLET\n    @Published var selectedTab: AppTab = .walletCards",
    "FILZA_NFCARD_DEFAULT_WALLET")

pairing = root / "PairingController.swift"
replace_once(pairing,
    '''    static func pairingFilePath() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]''',
    '''    static func pairingFilePath() -> String {
        // FILZA_NFCARD_SHARED_RP_PATH: prefer Filza's validated canonical record.
        // This is the same file ByeTunes, 3105 and Airlift consume.
        let manager = DeviceManager.shared
        manager.refreshExpectedPairingFileState()
        let shared = manager.rpPairingFile.path
        if manager.hasValidExpectedPairingFile,
           FileManager.default.isReadableFile(atPath: shared) {
            return shared
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]''',
    "FILZA_NFCARD_SHARED_RP_PATH")

txt = view.read_text()
assert "NFCARDPairingTab()" not in txt, "NFCARD pairing tab still visible"
assert "NFCARDWalletCardsTab()" in txt
assert "lastMainTab: AppTab = .walletCards" in txt
assert "selectedTab: AppTab = .walletCards" in vm.read_text()
assert "FILZA_NFCARD_SHARED_RP_PATH" in pairing.read_text()
print("NFCARD now uses the shared RP record; only Wallet Cards and Library remain visible")
