import Foundation
import UIKit
import Darwin
import Combine

// Filza-safe embedded utility surface for upstream 3105 1.1.1.
//
// The standalone 3105 Utils.swift also owns process-wide stdout/stderr capture,
// DisplayIdentity attestation, and its standalone update checker. Those belong
// to ThreeOneOSFiveApp/WindowGroup and are deliberately not installed into
// Filza's mixed Swift module. This adapter keeps the utility API used by the
// embedded 1.1.1 workspace while preserving Filza's lifecycle and diagnostics.

// MARK: - Global logger
class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published var entries: [String] = []

    func append(_ msg: String) {
        DispatchQueue.main.async { self.entries.append(msg) }
        print("[3105] \(msg)")
        FilzaDiagnosticsAppend("3105", msg)
    }
}

func log(_ msg: String) { AppLog.shared.append(msg) }

// MARK: - App Info
enum AppInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var versionTuple: (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }

    static var doubleVersion: Double {
        let v = versionTuple
        return Double(v.major) + Double(v.minor) / 10.0
    }

    static var osBuild: String {
        var size: size_t = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(cString: value)
    }

    static var machineName: String {
        var s = utsname()
        uname(&s)
        return Mirror(reflecting: s.machine).children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
    }

    static var displayMachineName: String {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineName
#else
        return machineName
#endif
    }

    static var hardwareDisplayName: String {
        switch displayMachineName {
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        default: return displayMachineName
        }
    }

    static var isHomeButton: Bool {
        let selector = NSSelectorFromString("_hasHomeButton")
        return UIDevice.responds(to: selector)
            && (UIDevice.perform(selector)?.takeUnretainedValue() as? Bool ?? false)
    }
}

// MARK: - Exploit status
enum ExploitStatus: Equatable {
    case notStarted
    case success(method: String)
    case failed(method: String, code: Int64)
    case unsupported(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    // Added by upstream 3105 1.1.1 and used by the embedded AppState to avoid
    // automatically retrying a failed kernel attempt in the same process.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .notStarted: return "Not attempted"
        case .success(let method): return "OK via \(method)"
        case .failed(let method, let code): return "FAILED \(method) (\(code))"
        case .unsupported(let message): return "Unsupported: \(message)"
        }
    }
}

enum AppPaths {
    static var backups: String {
        let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let backups = url.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return backups.path
    }

    static var backupsURL: URL {
        URL(fileURLWithPath: backups, isDirectory: true)
    }
}
