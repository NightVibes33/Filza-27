import Foundation
import Darwin

func hasReadWriteAccess(to path: String) -> Bool {
    let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        log("access check FAILED for \(path): errno=\(errno) \(String(cString: strerror(errno)))")
        return false
    }
    close(descriptor)
    log("access check OK (O_RDWR): \(path)")
    return true
}
