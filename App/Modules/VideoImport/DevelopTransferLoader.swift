import Foundation

/// A callback transfer must settle even when its provider ignores cancellation.
enum DevelopTransferLoader {
    enum TransferError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "The photo or video transfer timed out. Check your connection and try selecting it again."
        }
    }

    @MainActor
    static func load<Value: Sendable>(
        timeout: Duration = .seconds(120),
        onStart: (Progress) -> Void = { _ in },
        start: (@escaping @Sendable (Result<Value?, Error>) -> Void) -> Progress
    ) async throws -> Value? {
        try Task.checkCancellation()
        let state = TransferState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        state.finish(.failure(TransferError.timedOut), cancelProvider: true)
                    } catch {
                        // Completion cancels the timer; cancellation is not a timeout.
                    }
                }
                state.install(timer)
                guard state.isPending else { return }
                let progress = start { result in state.finish(result) }
                state.install(progress)
                onStart(progress)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()), cancelProvider: true)
        }
    }
}

/// All terminal decisions and resource installation are serialized by this lock.
/// Never call provider code or resume a continuation while holding the lock.
private final class TransferState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancelProvider = false
    private var buffered: Result<Value?, Error>?
    private var continuation: CheckedContinuation<Value?, Error>?
    private var progress: Progress?
    private var timer: Task<Void, Never>?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    func install(_ continuation: CheckedContinuation<Value?, Error>) -> Bool {
        lock.lock()
        if finished {
            let result = buffered!
            buffered = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancelProvider
        if !finished { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func install(_ timer: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = finished
        if !finished { self.timer = timer }
        lock.unlock()
        if shouldCancel { timer.cancel() }
    }

    func finish(_ result: Result<Value?, Error>, cancelProvider: Bool = false) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            // In particular, do not retain late transferred file leases.
            return
        }
        finished = true
        self.cancelProvider = cancelProvider
        let continuation = self.continuation
        let progress = self.progress
        let timer = self.timer
        self.continuation = nil
        self.progress = nil
        self.timer = nil
        if continuation == nil { buffered = result }
        lock.unlock()
        continuation?.resume(with: result)
        timer?.cancel()
        if cancelProvider { progress?.cancel() }
    }
}
