import SwiftUI
import UIKit
import Darwin
import MachO

private enum MondGestaltError: Error, LocalizedError {
    case invalidPlist
    case missingArtworkSubtype
    case missingArtworkDeviceName
    case writeValidationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlist: return "MobileGestalt.plist is invalid."
        case .missingArtworkSubtype: return "Failed to get ArtworkDeviceSubType."
        case .missingArtworkDeviceName: return "Failed to get ArtworkDeviceProductDescription."
        case .writeValidationFailed: return "The written plist failed validation."
        }
    }
}

private var mondOffsetCache: [String: Int] = [:]

private func mondCacheDataOffset(_ key: String) -> Int {
    if let cached = mondOffsetCache[key] { return cached }

    let libMG = "/usr/lib/libMobileGestalt.dylib"
    dlopen(libMG, RTLD_GLOBAL)

    var header: UnsafePointer<mach_header_64>?
    for index in 0..<_dyld_image_count() {
        guard let rawName = _dyld_get_image_name(index) else { continue }
        if String(cString: rawName) == libMG {
            header = unsafeBitCast(_dyld_get_image_header(index), to: UnsafePointer<mach_header_64>.self)
            break
        }
    }
    guard let header else { mondOffsetCache[key] = 0; return 0 }

    var textSize: UInt = 0
    guard let cstringBytes = getsectiondata(header, "__TEXT", "__cstring", &textSize) else {
        mondOffsetCache[key] = 0
        return 0
    }
    let start = cstringBytes.withMemoryRebound(to: CChar.self, capacity: Int(textSize)) { $0 }
    var keyPointer = start
    while keyPointer - start < Int(textSize) {
        if String(cString: keyPointer) == key { break }
        keyPointer += strlen(keyPointer) + 1
    }

    var constSize: UInt = 0
    var slots = getsectiondata(header, "__AUTH_CONST", "__const", &constSize)?
        .withMemoryRebound(to: UInt.self, capacity: Int(constSize) / 8) { $0 }
    if slots == nil {
        slots = getsectiondata(header, "__DATA_CONST", "__const", &constSize)?
            .withMemoryRebound(to: UInt.self, capacity: Int(constSize) / 8) { $0 }
    }
    guard let slots else { mondOffsetCache[key] = 0; return 0 }

    for index in 0..<(Int(constSize) / 8) where slots[index] == UInt(bitPattern: keyPointer) {
        let entry = slots.advanced(by: index).withMemoryRebound(to: UInt16.self, capacity: 1) { $0 }
        let offset = Int(entry[0x9a / 2] << 3)
        mondOffsetCache[key] = offset
        return offset
    }
    mondOffsetCache[key] = 0
    return 0
}

private func mondMachineName() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}

private func mondSystemVersion() -> Double {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return Double(version.majorVersion) + Double(version.minorVersion) / 10.0
}

private func mondHasHomeButton() -> Bool {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
    return (windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 0) == 0
}

private func mondBackupURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let directory = base.appendingPathComponent("GestaltManager", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("SavedGestalt.plist")
}

private struct MondToggle: View {
    let text: String
    let minimum: Double?
    @Binding var isOn: Bool

    init(_ text: String, minimum: Double? = nil, isOn: Binding<Bool>) {
        self.text = text
        self.minimum = minimum
        self._isOn = isOn
    }

    var body: some View {
        Toggle(text, isOn: $isOn)
            .disabled(minimum.map { mondSystemVersion() < $0 } ?? false)
    }
}

private struct MondInfoButton: View {
    let title: String
    let message: String
    let warning: Bool
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .alert(title, isPresented: $showing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

private func mondSupportsDisableDynamicIsland() -> Bool {
    let supported = [
        "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
        "iPhone16,1", "iPhone16,2", "iPhone17,3", "iPhone17,4",
        "iPhone17,1", "iPhone17,2", "iPhone18,3", "iPhone18,1",
        "iPhone18,2", "iPhone17,5"
    ]
    return supported.contains(mondMachineName()) && mondSystemVersion() < 19.0
}

private let mondAppleIntelligenceInstructions = """
How to use this tweak:
1. Spoof to the model next to the first one supported by Apple Intelligence.
2. Spoof back to your model.
3. Spoof to your final model and you should see the Apple Intelligence icon in Settings.
4. Connect iPhone to power and leave Settings > Storage open for about one hour.

Do not spoof back afterward.
"""

private let mondIPadUIWarning = """
This is a very dangerous tweak. Do not use it with an alphanumeric passcode. Do not turn off “Show Dock In Stage Manager” or the device can bootloop when rotating to landscape. Opening Stage Manager after enabling this can also enter Recovery Mode. Other instability, including app data disappearing, has been reported.
"""

struct MondGestaltView: View {
    let gestaltPath: String

    @AppStorage("mg_devicename") private var deviceName = ""
    @State private var plist = NSMutableDictionary()
    @State private var valid = true
    @State private var empty = false
    @State private var loading = false
    @State private var originalSubtype = 0
    @State private var selectedSubtype = "og"
    @State private var customDeviceName = false
    @State private var originalDeviceName = ""
    @State private var productType = ""
    @State private var message: String?

    private var cacheExtra: NSMutableDictionary? {
        if let mutable = plist["CacheExtra"] as? NSMutableDictionary { return mutable }
        if let existing = plist["CacheExtra"] as? NSDictionary {
            let mutable = existing.mutableCopy() as! NSMutableDictionary
            plist["CacheExtra"] = mutable
            return mutable
        }
        if plist.count > 0 {
            let mutable = NSMutableDictionary()
            plist["CacheExtra"] = mutable
            return mutable
        }
        return nil
    }

    private var selectedSubtypeValue: Int {
        switch selectedSubtype {
        case "og": return originalSubtype
        case "no_dynamic_island": return 0
        case "14p": return 2436
        case "14pm": return 2796
        case "15pm": return 2976
        case "16p": return 2622
        case "16pm": return 2868
        case "air": return 2736
        case "x": return 2436
        default: return originalSubtype
        }
    }

    var body: some View {
        List {
            if !valid || empty {
                Section {
                    if empty {
                        Label("Do not reboot — MobileGestalt.plist is empty.", systemImage: "exclamationmark.triangle.fill")
                    }
                    if !valid {
                        Label("Do not reboot — MobileGestalt.plist is invalid.", systemImage: "exclamationmark.triangle.fill")
                    }
                } header: {
                    Label("Warning", systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("Rebooting now may cause a bootloop. Use Revert Tweaks first and confirm the warning disappears.")
                }
            }

            Section {
                Button("Apply Tweaks", action: apply)
                Button("Revert Tweaks", role: .destructive, action: revert)
            } footer: {
                Text("WARNING: These tweaks can break device features or soft-brick the device if misused.")
            }

            Section {
                Picker("Subtype", selection: $selectedSubtype) {
                    Text("Original (\(originalSubtype))").tag("og")
                    if mondSupportsDisableDynamicIsland() {
                        Text("Disable Dynamic Island").tag("no_dynamic_island")
                    }
                    Text("iPhone 14 Pro").tag("14p")
                    Text("iPhone 14 Pro Max").tag("14pm")
                    Text("iPhone 15 Pro Max").tag("15pm")
                    if mondSystemVersion() >= 18.0 {
                        Text("iPhone 16 Pro").tag("16p")
                        Text("iPhone 16 Pro Max").tag("16pm")
                    }
                    if mondSystemVersion() >= 26.0 {
                        Text("iPhone Air").tag("air")
                    }
                    if mondHasHomeButton() { Text("iPhone X Gestures").tag("x") }
                }
                Toggle("Custom Device Name", isOn: $customDeviceName)
                if customDeviceName { TextField("Device Name", text: $deviceName) }
            } header: {
                Label("Device Artwork", systemImage: "paintbrush.pointed")
            }

            Section {
                MondToggle("Dynamic Island", minimum: 19.0, isOn: keyBinding(["YlEtTtHlNesRBMal1CqRaA"]))
                MondToggle("Always On Display", minimum: 18.0, isOn: keyBinding(["j8/Omm6s1lsmTDFsXjsBfA", "2OOJf1VhaM7NxfRok3HbWQ"]))
                MondToggle("AOD Vibrancy", minimum: 18.0, isOn: keyBinding(["ykpu7qyhqFweVMKtxNylWA"]))
                MondToggle("Charge Limit", minimum: 17.0, isOn: keyBinding(["37NVydb//GP/GrhuTN+exg"]))
                MondToggle("Boot Chime", isOn: keyBinding(["QHxt+hGLaBPbQJbXiUJX3w"]))
                MondToggle("Liquid Glass LPM", minimum: 19.0, isOn: keyBinding(["SAGvsp6O6kAQ4fEfDJpC4Q"]))
            } header: {
                Label("Software-Oriented Features", systemImage: "gearshape")
            }

            Section {
                MondToggle("Camera Control", minimum: 18.0, isOn: keyBinding(["CwvKxM2cEogD3p+HYgaW0Q", "oOV1jhJbdV3AddkcCg0AEA"]))
                MondToggle("Action Button", minimum: 17.0, isOn: keyBinding(["cT44WE1EohiwRzhsZ8xEsw"]))
                MondToggle("Crash Detection", isOn: keyBinding(["HCzWusHQwZDea6nNhaKndw"]))
                if mondHasHomeButton() { MondToggle("Enable Tap to Wake", isOn: keyBinding(["yZf3GTRMGTuwSV/lD7Cagw"])) }
                MondToggle("Pulse Width Modulation", minimum: 19.0, isOn: keyBinding(["6IejgN+1Fmu5/QrZFOIeNw"]))
            } header: {
                Label("Hardware-Oriented Features", systemImage: "iphone")
            }

            Section {
                MondToggle("Security Research Device UI", minimum: 26.0, isOn: keyBinding(["XYlJKKkj2hztRP1NWWnhlw"]))

                HStack(spacing: 10) {
                    Toggle("Disable Region Restrictions", isOn: regionBinding())
                    MondInfoButton(
                        title: "Region Restrictions",
                        message: "This tweak may be broken or have no effect on some iOS versions or devices.",
                        warning: false
                    )
                }

                HStack(spacing: 10) {
                    MondToggle("Apple Intelligence", minimum: 18.1, isOn: appleIntelligenceBinding())
                    MondInfoButton(
                        title: "Apple Intelligence",
                        message: mondAppleIntelligenceInstructions,
                        warning: false
                    )
                }

                HStack(spacing: 10) {
                    Picker("Spoofing", selection: $productType) {
                        Text("Default").tag(mondMachineName())
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            if mondSystemVersion() >= 17.4 {
                                Text("iPad Pro 11-inch (M4)").tag("iPad16,3")
                                Text("iPad Pro 11-inch (M4, Cellular)").tag("iPad16,4")
                            }
                            Text("iPad Pro 11-inch (4th Gen)").tag("iPad14,3")
                            Text("iPad Pro 11-inch (4th Gen, Cellular)").tag("iPad14,4")
                        } else {
                            Text("iPhone 15 Pro").tag("iPhone16,1")
                            Text("iPhone 15 Pro Max").tag("iPhone16,2")
                            if mondSystemVersion() >= 18.0 {
                                Text("iPhone 16").tag("iPhone17,3")
                                Text("iPhone 16 Plus").tag("iPhone17,4")
                                Text("iPhone 16 Pro").tag("iPhone17,1")
                                Text("iPhone 16 Pro Max").tag("iPhone17,2")
                            }
                            if mondSystemVersion() >= 19.0 {
                                Text("iPhone 17").tag("iPhone18,3")
                                Text("iPhone 17 Pro").tag("iPhone18,1")
                                Text("iPhone 17 Pro Max").tag("iPhone18,2")
                                Text("iPhone Air").tag("iPhone18,4")
                            }
                        }
                    }
                    MondInfoButton(
                        title: "Device Spoofing Info",
                        message: "Only spoof your device model to download Apple Intelligence. This may break Face ID. If you unspoof and want to keep Apple Intelligence, do not re-enter Apple Intelligence & Siri in Settings.",
                        warning: false
                    )
                }
            } header: {
                Label("Eligibility", systemImage: "checklist")
            }

            Section {
                MondToggle("Allow Installing iPadOS Apps", isOn: arrayBinding("9MZ5AdH43csAUajl/dU+IQ"))
                MondToggle("Apple Pencil Settings", isOn: keyBinding(["yhHcB0iH0d1XzPO/CFd3ow"]))
                if UIDevice.current.userInterfaceIdiom == .pad {
                    MondToggle("Stage Manager", isOn: keyBinding(["qeaj75wk3HF4DwQ8qbIi7g"]))
                }
                HStack(spacing: 10) {
                    Toggle("iPadOS UI", isOn: trollPadBinding())
                    MondInfoButton(title: "iPadOS UI Warning", message: mondIPadUIWarning, warning: true)
                }
                .disabled(cacheExtra?["+3Uf0Pm5F8Xy7Onyvko0vA"] as? String != "iPhone")
            } header: {
                Label("iPadOS Features", systemImage: "ipad")
            }

            Section {
                MondToggle("Internal Storage", isOn: keyBinding(["LBJfwOEzExRxzlAnSuI7eg"]))
                Toggle("Internal Features", isOn: internalBinding())
                MondToggle("Metal HUD in All Apps", isOn: keyBinding(["EqrsVvjcYDdxHBiQmGhAWw"]))
            } header: {
                Label("Internal", systemImage: "ant")
            }

        }
        .navigationTitle("Gestalt Editor")
        .onAppear(perform: load)
        .alert("Gestalt Editor", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func load() {
        guard !loading, plist.count == 0 else { return }
        loading = true
        let url = URL(fileURLWithPath: gestaltPath)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url)
                let object = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil)
                guard let loaded = object as? NSMutableDictionary else { throw MondGestaltError.invalidPlist }
                let backup = mondBackupURL()
                if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }

                let savedData = try Data(contentsOf: backup)
                let savedObject = try PropertyListSerialization.propertyList(from: savedData, options: [.mutableContainersAndLeaves], format: nil)
                guard let saved = savedObject as? NSMutableDictionary else { throw MondGestaltError.invalidPlist }
                let savedExtra = saved["CacheExtra"] as? NSMutableDictionary ?? NSMutableDictionary()
                let savedArtwork = savedExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? NSMutableDictionary()
                guard let subtype = savedArtwork["ArtworkDeviceSubType"] as? Int else { throw MondGestaltError.missingArtworkSubtype }
                guard let originalName = savedArtwork["ArtworkDeviceProductDescription"] as? String else { throw MondGestaltError.missingArtworkDeviceName }

                let extra = loaded["CacheExtra"] as? NSMutableDictionary ?? NSMutableDictionary()
                let artwork = extra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? NSMutableDictionary()
                let currentSubtype = artwork["ArtworkDeviceSubType"] as? Int ?? subtype
                let subtypeMap = [0: "no_dynamic_island", 2436: "14p", 2796: "14pm", 2976: "15pm", 2622: "16p", 2868: "16pm", 2736: "air"]
                let currentName = artwork["ArtworkDeviceProductDescription"] as? String ?? originalName
                let currentProduct = extra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String ?? mondMachineName()

                DispatchQueue.main.async {
                    self.plist = loaded
                    self.originalSubtype = subtype
                    self.selectedSubtype = subtypeMap[currentSubtype] ?? "og"
                    self.originalDeviceName = originalName
                    self.deviceName = currentName
                    self.customDeviceName = currentName != originalName
                    self.productType = currentProduct
                    self.empty = data.isEmpty
                    self.valid = true
                    self.loading = false
                    FilzaDiagnosticsAppend("Gestalt", "loaded MobileGestalt from \(gestaltPath)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.valid = false
                    self.empty = ((try? Data(contentsOf: url).isEmpty) ?? false)
                    self.loading = false
                    self.message = error.localizedDescription
                    FilzaDiagnosticsAppend("Gestalt", "load failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func apply() {
        guard let extra = cacheExtra else { return }
        if !productType.isEmpty { extra["h9jDsbgj7xIVeIQ8S3/X3Q"] = productType }
        let artworkKey = "oPeik/9e8lQWMszEjbPzng"
        let artwork = (extra[artworkKey] as? NSMutableDictionary) ?? NSMutableDictionary()
        artwork["ArtworkDeviceSubType"] = selectedSubtypeValue
        if customDeviceName { artwork["ArtworkDeviceProductDescription"] = deviceName }
        else { artwork["ArtworkDeviceProductDescription"] = originalDeviceName }
        extra[artworkKey] = artwork

        do {
            try write(plist)
            message = "Successfully applied Gestalt tweaks. Some changes require a respring or reboot."
            FilzaDiagnosticsAppend("Gestalt", "Gestalt changes written and validated")
        } catch {
            message = "Failed to apply MobileGestalt: \(error.localizedDescription)"
            FilzaDiagnosticsAppend("Gestalt", "write failed: \(error.localizedDescription)")
        }
    }

    private func revert() {
        do {
            if let error = FilzaGestaltRestoreBackup(gestaltPath) {
                throw error
            }
            plist = NSMutableDictionary()
            load()
            message = "Saved original MobileGestalt restored."
            FilzaDiagnosticsAppend("Gestalt", "restored saved Gestalt backup")
        } catch {
            message = "Failed to restore MobileGestalt: \(error.localizedDescription)"
        }
    }

    private func write(_ dictionary: NSMutableDictionary) throws {
        guard let bridgedDictionary = dictionary as? [AnyHashable: Any] else {
            throw NSError(
                domain: "FilzaSlop.Gestalt",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The MobileGestalt property list contains an unsupported key type."]
            )
        }

        if let error = FilzaGestaltWritePlist(gestaltPath, bridgedDictionary) {
            throw error
        }
    }

    private func keyBinding(_ keys: [String]) -> Binding<Bool> {
        Binding(get: {
            guard let extra = cacheExtra, let first = keys.first else { return false }
            return (extra[first] as? NSNumber)?.intValue == 1
        }, set: { enabled in
            guard let extra = cacheExtra else { return }
            for key in keys {
                if enabled { extra[key] = 1 } else { extra.removeObject(forKey: key) }
            }
        })
    }

    private func arrayBinding(_ key: String) -> Binding<Bool> {
        Binding(get: {
            guard let extra = cacheExtra else { return false }
            return (extra[key] as? [Int]) == [1, 2]
        }, set: { enabled in
            cacheExtra?[key] = enabled ? [1, 2] : [1]
        })
    }

    private func regionBinding() -> Binding<Bool> {
        Binding(get: {
            guard let extra = cacheExtra else { return false }
            return extra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "US" &&
                   extra["zHeENZu+wbg7PUprwNwBWg"] as? String == "LL/A"
        }, set: { enabled in
            guard let extra = cacheExtra else { return }
            if enabled {
                message = "Do not use this to bypass restrictions required by regional law, including mandatory camera shutter sounds."
                extra["h63QSdBCiT/z0WU6rdQv6Q"] = "US"
                extra["zHeENZu+wbg7PUprwNwBWg"] = "LL/A"
            } else {
                extra.removeObject(forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                extra.removeObject(forKey: "zHeENZu+wbg7PUprwNwBWg")
            }
        })
    }

    private func appleIntelligenceBinding() -> Binding<Bool> {
        let key = "A62OafQ85EJAiiqKn4agtg"
        return Binding(get: { (cacheExtra?[key] as? NSNumber)?.intValue == 1 }, set: { enabled in
            if enabled {
                cacheExtra?[key] = 1
                message = mondAppleIntelligenceInstructions
            } else {
                cacheExtra?.removeObject(forKey: key)
            }
        })
    }

    private func mutableCacheData() -> NSMutableData? {
        if let mutable = plist["CacheData"] as? NSMutableData { return mutable }
        if let data = plist["CacheData"] as? NSData {
            let mutable = data.mutableCopy() as! NSMutableData
            plist["CacheData"] = mutable
            return mutable
        }
        return nil
    }

    private func readCacheInt(_ key: String) -> Int64? {
        guard let data = mutableCacheData() else { return nil }
        let offset = mondCacheDataOffset(key)
        guard offset > 0, offset + MemoryLayout<Int64>.size <= data.length else { return nil }
        var value: Int64 = 0
        memcpy(&value, data.bytes.advanced(by: offset), MemoryLayout<Int64>.size)
        return value
    }

    private func writeCacheInt(_ key: String, value: Int64) {
        guard let data = mutableCacheData() else { return }
        let offset = mondCacheDataOffset(key)
        guard offset > 0, offset + MemoryLayout<Int64>.size <= data.length else { return }
        var mutableValue = value
        memcpy(data.mutableBytes.advanced(by: offset), &mutableValue, MemoryLayout<Int64>.size)
    }

    private func internalBinding() -> Binding<Bool> {
        let keys = ["EqrsVvjcYDdxHBiQmGhAWw", "Oji6HRoPi7rH7HPdWVakuw", "LBJfwOEzExRxzlAnSuI7eg"]
        return Binding(get: { readCacheInt(keys[0]) == 1 }, set: { enabled in
            for key in keys { writeCacheInt(key, value: enabled ? 1 : 0) }
        })
    }

    private func trollPadBinding() -> Binding<Bool> {
        let values = [
            "mG0AnH/Vy1veoqoLRAIgTA", "UCG5MkVahJxG1YULbbd5Bg",
            "ZYqko/XM5zD3XBfN5RmaXA", "nVh/gwNpy7Jv1NOk00CMrw", "uKc7FPnEO++lVhHWHFlGbQ"
        ]
        return Binding(get: {
            guard let extra = cacheExtra else { return false }
            return values.allSatisfy { (extra[$0] as? NSNumber)?.intValue == 1 }
        }, set: { enabled in
            guard let extra = cacheExtra else { return }
            if enabled { message = mondIPadUIWarning }
            writeCacheInt("mtrAoWJ3gsq+I90ZnQ0vQw", value: enabled ? 3 : 1)
            for key in values {
                if enabled { extra[key] = 1 } else { extra.removeObject(forKey: key) }
            }
        })
    }
}

@objc(MondGestaltHostFactory)
public final class MondGestaltHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(path: String) -> UIViewController {
        FilzaDiagnosticsAppend("Gestalt", "constructing complete embedded Gestalt Editor")
        let controller = UIHostingController(rootView: MondGestaltView(gestaltPath: path))
        controller.title = "Gestalt Editor"
        controller.view.backgroundColor = .systemGroupedBackground
        return controller
    }
}
