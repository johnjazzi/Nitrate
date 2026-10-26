import Foundation

/// Keeps an unqueued Develop file alive until the queue accepts ownership.
final class VideoImportFileLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let directory: URL?
    private var queueOwnsFile = false

    init(url: URL, directory: URL? = nil) {
        self.url = url
        self.directory = directory
    }

    func transferToQueue() {
        lock.lock()
        queueOwnsFile = true
        lock.unlock()
    }

    deinit {
        lock.lock()
        let shouldDiscard = !queueOwnsFile
        lock.unlock()
        if shouldDiscard {
            let ownedURL = url
            let ownedDirectory = directory
            Task { await VideoImportService.discard(ownedURL, directory: ownedDirectory) }
        }
    }
}
