import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS26Range = "26.0–26.6.1"

    static let verifiedIOS27Builds: [(beta: Int, build: String)] = [
        (1, "24A5355q"),
        (2, "24A5370h"),
        (3, "24A5380h"),
        (4, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            return minor < 6 || (minor == 6 && patch <= 1)
        }

        guard major == 27, minor == 0, patch == 0 else { return false }
        return iOS27BetaNumber(for: build) != nil
    }
}
