import Foundation
import Testing

/// Pure timestamp-driven progress: clamping, monotonicity and the one-percent
/// throttle that keeps progress off the per-frame path.
@Suite struct RenderProgressAccumulatorTests {
    private func approx(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    @Test func throttleEmitsWholePercentStepsOnly() {
        var accumulator = RenderProgressAccumulator(startSeconds: 0, durationSeconds: 1)
        #expect(accumulator.fraction(forAppendedSeconds: 0.005) == nil)
        #expect(approx(accumulator.fraction(forAppendedSeconds: 0.01), 0.01))
        #expect(accumulator.fraction(forAppendedSeconds: 0.015) == nil)
        #expect(approx(accumulator.fraction(forAppendedSeconds: 0.02), 0.02))
        #expect(approx(accumulator.fraction(forAppendedSeconds: 0.5), 0.5))
    }

    @Test func fractionNeverDecreasesAndRefusesStaleFrames() {
        var accumulator = RenderProgressAccumulator(startSeconds: 0, durationSeconds: 1)
        #expect(approx(accumulator.fraction(forAppendedSeconds: 0.5), 0.5))
        // A frame earlier than the last reported fraction is refused.
        #expect(accumulator.fraction(forAppendedSeconds: 0.4) == nil)
        #expect(accumulator.fraction(forAppendedSeconds: 0.5) == nil)
        #expect(approx(accumulator.fraction(forAppendedSeconds: 0.75), 0.75))
    }

    @Test func fractionIsClampedBelowOneUntilTheWriterFinishes() {
        var accumulator = RenderProgressAccumulator(startSeconds: 0, durationSeconds: 1)
        // A frame at or past the end of the range still reports below 1.
        #expect(approx(accumulator.fraction(forAppendedSeconds: 2), 0.99))
        #expect(accumulator.fraction(forAppendedSeconds: 5) == nil)
        // The terminal fraction is reserved for writer completion.
        #expect(RenderProgressAccumulator.finishFraction == 1)
    }

    @Test func timesBeforeTheRangeClampToZeroAndDoNotAdvance() {
        var accumulator = RenderProgressAccumulator(startSeconds: 10, durationSeconds: 1)
        #expect(accumulator.fraction(forAppendedSeconds: 9.5) == nil)
        #expect(approx(accumulator.fraction(forAppendedSeconds: 10.05), 0.05))
    }

    @Test func degenerateRangeNeverReportsAFraction() {
        var accumulator = RenderProgressAccumulator(startSeconds: 0, durationSeconds: 0)
        #expect(accumulator.fraction(forAppendedSeconds: 1) == nil)
    }
}

/// Queue phase transitions and the attempt fence, driven by injected deferred
/// render and save operations.
@Suite(.serialized) @MainActor
struct RenderJobProgressQueueTests {
    private enum Failure: Error { case render, save }

    private func files() throws -> (root: URL, source: URL, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("clip_import_fixture.mov")
        let output = root.appendingPathComponent("render_fixture.mov")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: output)
        return (root, source, output)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           _ message: String = "condition not reached") async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out: \(message)")
    }

    private func settle(_ model: RenderQueueViewModel) async throws {
        for _ in 0..<600 {
            if !model.isProcessing { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The queue did not settle.")
    }

    /// A resumable suspension point for an injected operation.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    @Test func queuePublishesRenderingThenSavingThenClearsOnCompletion() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let renderGate = Gate()
        let saveGate = Gate()
        let model = RenderQueueViewModel(render: { _ in await renderGate.wait(); return f.output },
            save: { _ in await saveGate.wait() }, persist: { _ in }, receipt: { _, _ in RenderReceipt() },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))

        try await waitUntil({ model.progress(for: id)?.phase == .rendering }, "rendering phase")
        // An injected render cannot report a real fraction, so it is included
        // as progress without a fabricated percentage.
        #expect(model.progress(for: id)?.fractionComplete == nil)

        renderGate.open()
        try await waitUntil({ model.progress(for: id)?.phase == .saving }, "saving phase")
        #expect(model.jobs.first?.status == .processing)
        // Saving is published before the Photos save, never as "already saved".
        #expect(model.jobs.first?.outputSavedToPhotos != true)

        saveGate.open()
        try await settle(model)
        #expect(model.jobs.first?.status == .completed)
        #expect(model.jobs.first?.outputSavedToPhotos == true)
        #expect(model.progress(for: id) == nil)
    }

    @Test func lateRenderCallbackCannotOverwriteSavingOrTerminalState() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let renderGate = Gate()
        let saveGate = Gate()
        let model = RenderQueueViewModel(render: { _ in await renderGate.wait(); return f.output },
            save: { _ in await saveGate.wait() }, persist: { _ in }, receipt: { _, _ in RenderReceipt() },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))

        try await waitUntil({ model.activeRenderAttempt(for: id) != nil }, "render attempt")
        let attempt = try #require(model.activeRenderAttempt(for: id))

        model.deliverRenderFraction(jobId: id, attempt: attempt, fraction: 0.5)
        #expect(model.progress(for: id)?.fractionComplete == 0.5)
        // Decreasing and wrong-attempt fractions are refused.
        model.deliverRenderFraction(jobId: id, attempt: attempt, fraction: 0.25)
        model.deliverRenderFraction(jobId: id, attempt: UUID(), fraction: 0.9)
        #expect(model.progress(for: id)?.fractionComplete == 0.5)

        renderGate.open()
        try await waitUntil({ model.progress(for: id)?.phase == .saving }, "saving phase")
        // A render callback from the superseded attempt cannot reopen rendering.
        model.deliverRenderFraction(jobId: id, attempt: attempt, fraction: 0.99)
        #expect(model.progress(for: id)?.phase == .saving)
        #expect(model.progress(for: id)?.fractionComplete == nil)

        saveGate.open()
        try await settle(model)
        // Even a callback after completion is refused; nothing is retained.
        model.deliverRenderFraction(jobId: id, attempt: attempt, fraction: 0.9)
        #expect(model.progress(for: id) == nil)
    }

    @Test func progressIsClearedOnRenderFailure() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let renderGate = Gate()
        let model = RenderQueueViewModel(render: { _ in await renderGate.wait(); throw Failure.render },
            save: { _ in }, persist: { _ in }, receipt: { _, _ in RenderReceipt() },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        try await waitUntil({ model.progress(for: id)?.phase == .rendering }, "rendering phase")
        renderGate.open()
        try await settle(model)
        #expect(model.jobs.first?.status == .failed)
        #expect(model.progress(for: id) == nil)
    }

    @Test func retryOfRetainedOutputDoesNotRerender() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(render: { _ in renders += 1; return f.output },
            save: { _ in saves += 1; if saves == 1 { throw Failure.save } },
            persist: { _ in }, receipt: { _, _ in RenderReceipt() },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        try await settle(model)
        #expect(model.jobs.first?.status == .failed)
        #expect(model.progress(for: id) == nil)

        model.retry(jobId: id)
        try await settle(model)
        #expect(model.jobs.first?.status == .completed)
        // The retained output is re-saved, not re-rendered.
        #expect(renders == 1 && saves == 2)
    }
}
