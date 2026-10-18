import Foundation
import Testing

@MainActor
@Suite("Private export delivery cleanup")
struct RenderQueueExportCleanupTests {
    private enum Failure: Error { case denied }

    private func settle(_ queue: RenderQueueViewModel) async {
        for _ in 0..<500 where queue.isProcessing {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!queue.isProcessing)
    }

    @Test(arguments: [false, true])
    func cleansOnlyAfterAllRequiredDeliveriesAreDurable(saveOriginal: Bool) async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        var saves: [URL] = []
        var durable: [RenderJob] = []
        var diagnostic = false
        let queue = RenderQueueViewModel(render: { _ in output }, save: { url in
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(FileManager.default.fileExists(atPath: output.path))
            #expect(durable.first?.receipt != nil)
            saves.append(url)
        }, postDelivery: { url, _ in
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(durable.first?.status == .completed)
            diagnostic = true
        }, persist: { durable = $0 }, receipt: { _, elapsed in
            RenderReceipt(renderDurationSeconds: elapsed)
        }, mediaCleanup: fixture.cleaner)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100,
                      deliveryPreferences: .init(saveOriginalLog: saveOriginal))
        await settle(queue)
        #expect(saves == (saveOriginal ? [output, source] : [output]))
        #expect(diagnostic)
        #expect(queue.jobs.first?.status == .completed)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
        #expect(queue.jobs.first?.receipt?.renderDurationSeconds != nil)
        #expect(queue.jobs.first?.outputURL == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(durable.first?.mediaCleanupCompleted == true)
    }

    @Test(arguments: [false, true])
    func failedOrPartialSaveRetainsBothFiles(denyOriginalOnly: Bool) async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        let queue = RenderQueueViewModel(render: { _ in output }, save: { url in
            if !denyOriginalOnly || url == source { throw Failure.denied }
        }, persist: { _ in }, receipt: { _, _ in RenderReceipt() }, mediaCleanup: fixture.cleaner)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100,
                      deliveryPreferences: .init(saveOriginalLog: true))
        await settle(queue)
        #expect(queue.jobs.first?.status == .failed)
        #expect(queue.jobs.first?.mediaCleanupCompleted != true)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func terminalPersistenceFailureNeverDeletesAndResumeDoesNotSaveTwice() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        var blocked = true
        var saves = 0
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in saves += 1 }, persist: { jobs in
            if blocked && jobs.first?.status == .completed { throw Failure.denied }
        }, receipt: { _, _ in RenderReceipt() }, mediaCleanup: fixture.cleaner)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100)
        await settle(queue)
        #expect(queue.isPersistenceBlocked)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
        blocked = false
        queue.resume()
        await settle(queue)
        #expect(saves == 1)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
    }

    @Test func relaunchResumesCleanupWithoutSavingAndLeavesLegacyHistoryAlone() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        let legacySource = try fixture.movie("clip_legacy.mov", in: fixture.sources)
        var completed = RenderJob(sourceURL: source, stockId: "test", iso: 100)
        completed.status = .completed
        completed.outputURL = output
        completed.outputSavedToPhotos = true
        completed.receipt = RenderReceipt()
        var legacy = RenderJob(sourceURL: legacySource, stockId: "old", iso: 100)
        legacy.status = .completed
        let persisted = [completed, legacy]
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in
            Issue.record("Cleanup must not repeat Photos delivery")
        }, persist: { _ in }, load: { persisted }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: legacySource.path))
        #expect(queue.jobs.last?.receipt == nil)
    }

    @Test func outstandingCrossRoleReferenceProtectsMovieUntilLastConsumerFinishes() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let shared = try fixture.movie("render_shared.mov", in: fixture.outputs)
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        var completed = RenderJob(sourceURL: source, stockId: "test", iso: 100)
        completed.status = .completed
        completed.outputURL = shared
        completed.outputSavedToPhotos = true
        completed.receipt = RenderReceipt()
        let awaiting = RenderJob(awaitingStockSourceURL: shared)
        let persisted = [completed, awaiting]
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
                                        persist: { _ in }, load: { persisted },
                                        receipt: { _, elapsed in
            #expect(elapsed == nil)
            return RenderReceipt()
        }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(queue.jobs.first?.mediaCleanupCompleted != true)
        queue.exportOriginal(jobId: awaiting.id)
        await settle(queue)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        #expect(queue.jobs.allSatisfy { $0.mediaCleanupCompleted == true })
        #expect(queue.jobs.last?.outputSavedToPhotos != true)
    }

    @Test func cleanupErrorRetriesOnActivationWithoutDuplicateDelivery() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        var fails = true
        var saves = 0
        let cleanup = RenderMediaCleanup(sourceRoot: fixture.sources, outputRoot: fixture.outputs, remove: { url in
            if fails { throw Failure.denied }
            try FileManager.default.removeItem(at: url)
        })
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in saves += 1 },
                                        persist: { _ in }, receipt: { _, _ in RenderReceipt() }, mediaCleanup: cleanup)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100)
        await settle(queue)
        #expect(queue.jobs.first?.status == .completed)
        #expect(queue.jobs.first?.cleanupWarning != nil)
        #expect(queue.jobs.first?.mediaCleanupCompleted != true)
        fails = false
        queue.retryMediaCleanup()
        await settle(queue)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
        #expect(queue.jobs.first?.cleanupWarning == nil)
        #expect(saves == 1)
    }

    @Test func receiptPersistenceFailurePreventsPhotosAndCleanup() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        var saves = 0
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in saves += 1 }, persist: { jobs in
            if jobs.first?.receipt != nil { throw Failure.denied }
        }, receipt: { _, _ in RenderReceipt() }, mediaCleanup: fixture.cleaner)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100)
        await settle(queue)
        #expect(saves == 0)
        #expect(queue.isPersistenceBlocked)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cleanupWriteCrashWindowRecoversMissingMoviesWithoutDelivery() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_take.mov", in: fixture.sources)
        let output = try fixture.movie("render_take.mov", in: fixture.outputs)
        var durable: [RenderJob] = []
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in }, persist: { jobs in
            if jobs.first?.mediaCleanupCompleted == true { throw Failure.denied }
            durable = jobs
        }, receipt: { _, _ in RenderReceipt() }, mediaCleanup: fixture.cleaner)
        queue.enqueue(sourceURL: source, stockId: "test", iso: 100)
        await settle(queue)
        #expect(queue.isPersistenceBlocked)
        #expect(durable.first?.status == .completed)
        #expect(durable.first?.outputURL == output)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let snapshot = durable
        let recovered = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in
            Issue.record("Cleanup recovery must not deliver again")
        }, persist: { _ in }, load: { snapshot }, mediaCleanup: fixture.cleaner)
        recovered.onAppear()
        await settle(recovered)
        #expect(recovered.jobs.first?.mediaCleanupCompleted == true)
        #expect(recovered.jobs.first?.outputURL == nil)
    }

    @Test func reusedOutputHasNoInventedRenderDurationAndFailedSharedSourceIsProtected() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_shared.mov", in: fixture.sources)
        let output = try fixture.movie("render_existing.mov", in: fixture.outputs)
        var ready = RenderJob(sourceURL: source, stockId: "test", iso: 100)
        ready.outputURL = output
        var failed = RenderJob(sourceURL: source, stockId: "failed", iso: 100)
        failed.status = .failed
        let snapshot = [ready, failed]
        let queue = RenderQueueViewModel(render: { _ in
            Issue.record("An existing output must not be rendered again")
            return output
        }, save: { _ in }, persist: { _ in }, load: { snapshot }, receipt: { url, elapsed in
            #expect(url == output)
            #expect(elapsed == nil)
            return RenderReceipt()
        }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(queue.jobs.first?.receipt?.renderDurationSeconds == nil)
        #expect(queue.jobs.first?.mediaCleanupCompleted != true)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
