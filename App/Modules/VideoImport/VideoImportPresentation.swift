import Foundation

/// File ownership stays with the import sheet until a durable queue acceptance.
struct VideoImportPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, transferring, validating, ready }
    private(set) var phase: Phase = .idle
    private(set) var generation = UUID()
    private(set) var selectedURL: URL?
    private(set) var selectedStockID: String?
    private(set) var errorMessage: String?

    var isLoading: Bool { phase == .transferring || phase == .validating }
    var canRender: Bool { phase == .ready && selectedURL != nil && selectedStockID != nil }

    mutating func begin() -> UUID {
        reset()
        phase = .transferring
        return generation
    }

    mutating func validating(_ token: UUID) -> Bool {
        guard token == generation, phase == .transferring else { return false }
        phase = .validating
        return true
    }

    mutating func accept(url: URL, token: UUID) -> Bool {
        guard token == generation, isLoading else { return false }
        selectedURL = url
        phase = .ready
        errorMessage = nil
        return true
    }

    mutating func selectStock(_ id: String) {
        guard phase == .ready, !id.isEmpty else { return }
        selectedStockID = id
    }

    mutating func fail(_ message: String, token: UUID) {
        guard token == generation else { return }
        phase = .idle
        selectedURL = nil
        selectedStockID = nil
        errorMessage = message
    }

    mutating func enqueueFailed(_ message: String) {
        errorMessage = message
    }

    /// Caller invokes this only after enqueueImportedVideo returned a durable ID.
    mutating func submitted() -> URL? {
        guard canRender else { return nil }
        let url = selectedURL
        reset()
        return url
    }

    mutating func reset() {
        generation = UUID()
        phase = .idle
        selectedURL = nil
        selectedStockID = nil
        errorMessage = nil
    }
}

/// Covers cancellation after a provider has copied a file but before its result
/// reaches the sheet. A discarded Transferable releases its unqueued file too.
final class VideoImportFileLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var queueOwnsFile = false

    init(url: URL) { self.url = url }

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
            Task { await VideoImportService.discard(ownedURL) }
        }
    }
}
