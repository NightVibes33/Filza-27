import Foundation
import Darwin

func sandbox_extension_consume(_ token: String) -> Int64? {
    typealias Fn = @convention(c) (UnsafePointer<CChar>?) -> Int64
    guard let lib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }
    guard let sym = dlsym(lib, "sandbox_extension_consume") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    return fn(token)
}

func sandbox_extension_issue_file(path: String) -> String? {
    typealias Fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32) -> UnsafeMutablePointer<CChar>?
    guard let lib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(lib) }
    guard let sym = dlsym(lib, "sandbox_extension_issue_file") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    guard let ptr = fn("com.apple.app-sandbox.read-write", path, 0, 0) else { return nil }
    defer { free(ptr) }
    return String(cString: ptr)
}
