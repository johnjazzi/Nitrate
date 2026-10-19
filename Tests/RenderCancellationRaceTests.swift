import CoreMedia
import CoreVideo
import Foundation
import Testing

/// Regression coverage for the render-cancellation race fix.
///
/// A wedged `AVAssetReader` can leave a pending `AVAssetReaderOutput.Provider.next()`
/// suspended forever: cancelling the writer and the readers does not reliably
/// resume it. The render loop therefore races every provider read against an
/// explicit `CancellationGate` owned by `RenderCancellationHandle`, so a read
/// that never returns can no longer pin the render task.
///
/// The writer append has the same hazard, so the video lane races it too — see
/// `blockedVideoAppendIsReleasedByCancellation`.
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

    /// (g) THE VIDEO-APPEND SEAM. The receiver's `append(_:with:)` takes a
    /// `CVReadOnlyPixelBuffer` — a `Sendable` reference — so a cancel landing
    /// while the append waits on writer backpressure must release the racing
    /// caller promptly. This is the exact shape `PipelineRenderer.renderFrame`
    /// uses: a real read-only pixel buffer crosses into the raced task beside a
    /// non-`Sendable` receiver box. The old code treated this as impossible
    /// because the output buffer is move-only; the move-only buffer is consumed
    /// into the `Sendable` read-only view *before* it is boxed, so nothing
    /// move-only ever crosses the boundary.
    @Test(.timeLimit(.minutes(1)))
    func blockedVideoAppendIsReleasedByCancellation() async throws {
        let gate = CancellationGate()
        let receiver = BlockingPixelBufferReceiver()
        let buffer = try #require(makeReadOnlyPixelBuffer())
        let inputs = RacedInputs((receiver: receiver, buffer: buffer, time: CMTime.zero))
        let started = ContinuousClock.now

        let call = Task { () -> Error? in
            do {
                try await raceAgainstCancellation(gate: gate) {
                    let inputs = inputs.value
                    try await inputs.receiver.append(inputs.buffer, with: inputs.time)
                }
                return nil
            } catch {
                return error
            }
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while !receiver.appendEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receiver.appendEntered, "the append was never entered")
        gate.signal()

        let error = await call.value
        #expect(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        #expect(ContinuousClock.now - started < .seconds(10),
                "the raced append was not released promptly after the gate was signalled")
    }
}

/// Test double for `AVAssetWriterInput.PixelBufferReceiver.append`: records that
/// it was entered, then parks until the racing task cancels it — the writer
/// backpressure a cancelled writer never releases.
private final class BlockingPixelBufferReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false

    var appendEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    private func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }

    func append(_ buffer: CVReadOnlyPixelBuffer, with time: CMTime) async throws {
        markEntered()
        try await Task.sleep(for: .seconds(3600))
    }
}

/// A real (empty) read-only pixel buffer — the `Sendable` value the receiver's
/// append takes. Built from a genuine `CVPixelBuffer`, not synthesised data.
private func makeReadOnlyPixelBuffer() -> CVReadOnlyPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                              nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { return nil }
    return CVReadOnlyPixelBuffer(CVMutablePixelBuffer(unsafeBuffer: pixelBuffer))
}
