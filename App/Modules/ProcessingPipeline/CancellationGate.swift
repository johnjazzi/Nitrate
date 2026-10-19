import Foundation

/// A one-shot cancellation gate.
///
/// `signal()` latches a flag and resumes every waiter already parked; any
/// `wait()` after that returns immediately. It exists because a wedged
/// `AVAssetReader` can leave a pending `AVAssetReaderOutput.Provider.next()`
/// suspended forever — cancelling the writer and the readers does NOT reliably
/// resume it — so the render loop needs its own explicit release signal to race
/// each provider read against.
///
/// Waiters are individually cancellable: a `wait()` whose task is cancelled
/// un-parks and returns, so a race that loses to its operation cannot leak a
/// parked continuation. The gate therefore tolerates more than one concurrent
/// waiter, which the two render lanes (video frame loop, audio copy) require.
final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextToken: UInt64 = 0

    /// True once `signal()` has run; never resets.
    var isSignalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalled
    }

    /// Returns immediately if the gate has been signalled; otherwise parks the
    /// current task until `signal()` — or the task's own cancellation — resumes it.
    func wait() async {
        if isSignalled { return }
        let token = reserveToken()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signalled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[token] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            // Un-park this waiter so a cancelled task never hangs here.
            let parked: CheckedContinuation<Void, Never>?
            lock.lock()
            parked = waiters.removeValue(forKey: token)
            lock.unlock()
            parked?.resume()
        }
    }

    /// Latches the gate and resumes every parked waiter. Safe to call
    /// repeatedly, from any thread, in any order: only the first call has an
    /// effect, and each parked continuation is resumed exactly once.
    func signal() {
        lock.lock()
        if signalled {
            lock.unlock()
            return
        }
        signalled = true
        let parked = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for continuation in parked {
            continuation.resume()
        }
    }

    private func reserveToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        return token
    }
}

/// Awaits `operation`, but throws `CancellationError` as soon as `gate` is
/// signalled — whichever finishes first wins.
///
/// The operation runs in an unstructured task that is deliberately abandoned
/// (never joined) when the gate wins, so a wedged reader whose `next()` never
/// resumes cannot pin the caller. The operation's payload may be non-`Sendable`,
/// so `operation` returns `Void` and parks its result in a caller-supplied
/// lock-protected box; nothing but the box crosses the task boundary.
func raceAgainstCancellation(
    gate: CancellationGate,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let relay = RaceRelay()

    let operationTask = Task {
        do {
            try await operation()
            relay.resolve(.success(()))
        } catch {
            relay.resolve(.failure(error))
        }
    }
    let gateWatcher = Task {
        await gate.wait()
        relay.resolve(.failure(CancellationError()))
    }

    do {
        try await relay.wait()
        // The operation won the race; release the parked gate watcher.
        gateWatcher.cancel()
    } catch {
        // The gate won (or the operation failed). Abandon the operation task
        // rather than joining it: a wedged provider read never returns.
        operationTask.cancel()
        throw error
    }
}

/// Bridges the two racing producers (the operation task and the gate watcher)
/// to a single continuation with take-once semantics, so a double resume — a
/// fatal error for a checked continuation — can never occur.
private final class RaceRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var buffered: Result<Void, Error>?
    private var settled = false

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var pending: Result<Void, Error>?
            lock.lock()
            if let buffered {
                pending = buffered
            } else {
                self.continuation = continuation
            }
            lock.unlock()
            if let pending { continuation.resume(with: pending) }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let parked = continuation
        continuation = nil
        if parked == nil { buffered = result }
        lock.unlock()
        parked?.resume(with: result)
    }
}

/// Carries a value out of a raced operation's task without requiring the value
/// to be `Sendable`: only the box crosses the boundary, and the caller reads it
/// after the race has resolved.
final class SampleBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
