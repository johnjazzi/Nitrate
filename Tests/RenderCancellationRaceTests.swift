import Foundation
import Testing

/// Regression coverage for the render-cancellation race fix.
///
/// A wedged `AVAssetReader` can leave a pending `AVAssetReaderOutput.Provider.next()`
/// suspended forever: cancelling the writer and the readers does not reliably
/// resume it. The render loop therefore races every provider read against an
/// explicit `CancellationGate` owned by `RenderCancellationHandle`, so a read
/// that never returns can no longer pin the render task.
private enum RaceTestError: Error {
    case boom
}

struct RenderCancellationRaceTests {
    /// (a) A gate signalled before `wait()` returns immediately.
    @Test func waitReturnsImmediatelyWhenAlreadySignalled() async {
        let gate = CancellationGate()
        gate.signal()

        let started = ContinuousClock.now
        await gate.wait()
        let elapsed = ContinuousClock.now - started

        #expect(gate.isSignalled)
        #expect(elapsed < .seconds(1), "already-signalled wait() took \(elapsed)")
    }

    /// (b) A parked `wait()` resumes once the gate is signalled.
    @Test func parkedWaitResumesWhenSignalled() async {
        let gate = CancellationGate()
        let waiter = Task { await gate.wait() }

        // Give the waiter a chance to park before signalling.
        try? await Task.sleep(for: .milliseconds(50))
        gate.signal()
        await waiter.value

        #expect(gate.isSignalled)
    }

    /// (c) `signal()` is idempotent and safe to call repeatedly, from any order.
    @Test func signalIsIdempotent() async {
        let gate = CancellationGate()
        let waiter = Task { await gate.wait() }

        try? await Task.sleep(for: .milliseconds(50))
        gate.signal()
        gate.signal()
        gate.signal()
        await waiter.value

        // A later wait() still returns immediately rather than parking.
        await gate.wait()
        #expect(gate.isSignalled)
    }

    /// (d) THE KEY REGRESSION. The raced operation never completes; signalling
    /// the gate must make the raced call throw `CancellationError` promptly.
    ///
    /// The elapsed-time assertion is the real check. The one-minute time limit
    /// bounds the test so that a naive `await operation()` implementation fails
    /// (rather than wedging the whole suite on the hour-long sleep).
    @Test(.timeLimit(.minutes(1)))
    func raceReturnsPromptlyWhenGateSignalled() async throws {
        let gate = CancellationGate()
        let started = ContinuousClock.now

        let call = Task { () -> Error? in
            do {
                try await raceAgainstCancellation(gate: gate) {
                    // Effectively never completes within the test's lifetime.
                    try await Task.sleep(for: .seconds(3600))
                }
                return nil
            } catch {
                return error
            }
        }

        // Let the raced operation park, then release the gate.
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()

        let error = await call.value
        let elapsed = ContinuousClock.now - started

        #expect(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        #expect(elapsed < .seconds(10), "raced call took \(elapsed) after the gate was signalled")
    }

    /// (e) When the gate never fires, the operation's own error still propagates.
    @Test func operationErrorPropagatesWhenGateNeverFires() async {
        let gate = CancellationGate()
        var caught: Error?
        do {
            try await raceAgainstCancellation(gate: gate) {
                throw RaceTestError.boom
            }
        } catch {
            caught = error
        }

        #expect(caught is RaceTestError)
        #expect(!gate.isSignalled)
    }

    /// (f) `RenderCancellationHandle.cancel()` signals its gate.
    @Test func cancelSignalsTheGate() {
        let handle = RenderCancellationHandle(writer: nil, videoReader: nil, audioReader: nil)

        #expect(!handle.cancellationGate.isSignalled)
        handle.cancel()
        #expect(handle.cancellationGate.isSignalled)
    }
}
