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

root_old = """struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        TabView(selection: $vm.selectedTab) {"""
root_new = """struct ContentView: View {
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
                TabView(selection: airCardTabSelection) {"""
assert root_old in s, "ContentView root changed upstream"
s = s.replace(root_old, root_new, 1)

tabs_old = """            PasscodeThemeTab()
                .tabItem { Label("Passcode", systemImage: "lock.circle.fill") }
                .tag(AppTab.passcodeThemes)

            TendiesView()
                .tabItem { Label("Wallpapers", systemImage: "photo.stack.fill") }
                .tag(AppTab.wallpapers)"""
tabs_new = """            Color.clear
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.cardLibrary)"""
assert tabs_old in s, "Root tab layout changed upstream"
s = s.replace(tabs_old, tabs_new, 1)

cover_old = """        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
        }
    }
}"""
cover_new = """        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
            if vm.selectedTab != .cardLibrary {
                lastMainTab = vm.selectedTab
            }
        }
    }
}"""
assert cover_old in s, "ContentView modifier layout changed upstream"
s = s.replace(cover_old, cover_new, 1)

s = s.replace(
    "Apple Wallet Skins & Passcode Themes for iOS 18+",
    "Apple Wallet card skins on iOS"
)
s = s.replace(
    "Apply custom wallet card skins and passcode themes on-device using the AirTraffic sandbox escape.",
    "Apply custom Apple Wallet card skins on-device."
)
content.write_text(s)

info_path = src / "ios-app/Info.plist"
with info_path.open("rb") as fh:
    info = plistlib.load(fh)

info["CFBundleDisplayName"] = "AirCard"
info["NSPhotoLibraryUsageDescription"] = "AirCard needs photo access to apply custom Apple Wallet card skins."
info["WKAppBoundDomains"] = ["cardmaker-omega.vercel.app"]

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

project = src / "project.yml"
s = project.read_text()
s = s.replace(
    "PRODUCT_BUNDLE_IDENTIFIER: com.mak5er.aircard",
    "PRODUCT_BUNDLE_IDENTIFIER: com.nightvibes33.aircard"
)
project.write_text(s)
