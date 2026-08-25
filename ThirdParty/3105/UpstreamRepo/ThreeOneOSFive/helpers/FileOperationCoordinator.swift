import Foundation

struct FileOperationPayload: Equatable {
    let mode: FileTransferMode
    let sourceURLs: [URL]

    var itemCount: Int { sourceURLs.count }
}

struct FileTransferSession: Equatable {
    let destinationDirectory: URL
    let mode: FileTransferMode
    private(set) var pendingSourceURLs: [URL]
    private(set) var replaceAll = false
    private(set) var keepBothAll = false
    private(set) var copiedCount = 0
    private(set) var movedCount = 0
    private(set) var replacedCount = 0
    private(set) var renamedCount = 0
    private(set) var failedCount = 0
    private(set) var isCancelled = false

    init(payload: FileOperationPayload, destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
        self.mode = payload.mode
        self.pendingSourceURLs = payload.sourceURLs
    }

    var isComplete: Bool { pendingSourceURLs.isEmpty }

    mutating func takeNext() -> URL? {
        guard !pendingSourceURLs.isEmpty else { return nil }
        return pendingSourceURLs.removeFirst()
    }

    mutating func useReplaceAll() {
        replaceAll = true
        keepBothAll = false
    }

    mutating func useKeepBothAll() {
        keepBothAll = true
        replaceAll = false
    }

    mutating func record(_ disposition: FileTransferDisposition) {
        switch disposition {
        case .copied: copiedCount += 1
        case .moved: movedCount += 1
        case .replaced: replacedCount += 1
        case .renamed: renamedCount += 1
        }
    }

    mutating func recordFailure() {
        failedCount += 1
    }

    mutating func cancel() {
        pendingSourceURLs.removeAll()
        isCancelled = true
    }
}

@MainActor
final class FileOperationCoordinator: ObservableObject {
    @Published private(set) var payload: FileOperationPayload?

    func prepare(_ sourceURLs: [URL], mode: FileTransferMode) {
        let uniqueURLs = Array(Set(sourceURLs.map(\.standardizedFileURL)))
            .sorted { $0.path < $1.path }
        payload = uniqueURLs.isEmpty
            ? nil
            : FileOperationPayload(mode: mode, sourceURLs: uniqueURLs)
    }

    func clear() {
        payload = nil
    }
}
