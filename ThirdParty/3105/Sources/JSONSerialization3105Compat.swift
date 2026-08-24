import Foundation

extension JSONSerialization {
    nonisolated static func jsonObject(
        from data: Data,
        options opt: ReadingOptions = []
    ) throws -> Any {
        try jsonObject(with: data, options: opt)
    }
}
