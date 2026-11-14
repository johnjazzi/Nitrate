import Foundation
import Testing

/// Regression for the physical-device startup watchdog: historical still rows
/// predate isPhoto and must never enter the movie-only cleanup sweep.
@MainActor
struct LegacyPhotoStartupCleanupTests {
    private enum Failure: Error { case unexpectedRender }

    private func legacyPhoto(source: URL, output: URL?) -> RenderJob {
        var job = RenderJob(sourceURL: source, stockId: "legacy", iso: 100)
        job.status = .completed
        job.outputURL = output
        job.sourceSavedToPhotos = true
        job.outputSavedToPhotos = true
        job.receipt = RenderReceipt(durationSeconds: 2)
        job.mediaCleanupCompleted = false
        job.cleanupWarning = "Local movie was not removed because its app ownership could not be verified."
        return job
    }

    private func settle(_ queue: RenderQueueViewModel) async {
        for _ in 0..<500 where queue.isProcessing {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!queue.isProcessing)
    }

    @Test func legacyStillHistoryDoesNotTriggerStartupOrRetryWrites() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        var removes: [URL] = []
        let cleanup = RenderMediaCleanup(sourceRoot: fixture.sources, outputRoot: fixture.outputs, remove: { url in
            removes.append(url)
            try FileManager.default.removeItem(at: url)
        })
        var snapshot: [RenderJob] = []
        for index in 0..<427 {
            let source = try fixture.movie("clip_legacy_\(index).dng", in: fixture.sources)
            let output = try fixture.movie("render_legacy_\(index).jpg", in: fixture.outputs)
            snapshot.append(legacyPhoto(source: source, output: output))
        }
        let noOutput = try fixture.movie("clip_legacy_no_output.dng", in: fixture.sources)
        snapshot.append(legacyPhoto(source: noOutput, output: nil))
        var writes = 0
        let queue = RenderQueueViewModel(render: { _ in throw Failure.unexpectedRender }, save: { _ in
            Issue.record("Startup cleanup must not deliver media")
        }, persist: { _ in writes += 1 }, load: { snapshot }, mediaCleanup: cleanup)
        queue.onAppear()
        await settle(queue)
        queue.retryMediaCleanup()
        await settle(queue)
        queue.onAppear()
        await settle(queue)
        #expect(writes == 0, "Legacy still rows cannot be removed by movie cleanup and must not rewrite the queue")
        #expect(removes.isEmpty)
        let historyUnchanged = queue.jobs == snapshot
        #expect(historyUnchanged, "Existing receipts, cleanup warnings and files must remain untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sources.path).count == 428)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputs.path).count == 427)
    }

    @Test func unsupportedUppercaseMovieDoesNotBecomeAPermanentCleanupCandidate() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_legacy.MOV", in: fixture.sources)
        let snapshot = [legacyPhoto(source: source, output: nil)]
        var writes = 0
        let queue = RenderQueueViewModel(render: { _ in throw Failure.unexpectedRender }, save: { _ in
            Issue.record("Cleanup must not deliver media")
        }, persist: { _ in writes += 1 }, load: { snapshot }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(writes == 0, "Eligibility must match the cleanup capability's case-sensitive extension check")
        let historyUnchanged = queue.jobs == snapshot
        #expect(historyUnchanged)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func deliveredMovieStillCleansUpBesideLegacyPhoto() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        let photoSource = try fixture.movie("clip_legacy.dng", in: fixture.sources)
        let photoOutput = try fixture.movie("render_legacy.jpg", in: fixture.outputs)
        var movie = RenderJob(sourceURL: source, stockId: "test", iso: 100)
        movie.status = .completed
        movie.outputURL = output
        movie.outputSavedToPhotos = true
        movie.receipt = RenderReceipt()
        let photo = legacyPhoto(source: photoSource, output: photoOutput)
        let queue = RenderQueueViewModel(render: { _ in throw Failure.unexpectedRender }, save: { _ in
            Issue.record("Cleanup must not deliver media")
        }, persist: { _ in }, load: { [movie, photo] }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let photoUnchanged = queue.jobs.last == photo
        #expect(photoUnchanged)
        #expect(FileManager.default.fileExists(atPath: photoSource.path))
        #expect(FileManager.default.fileExists(atPath: photoOutput.path))
    }
}
