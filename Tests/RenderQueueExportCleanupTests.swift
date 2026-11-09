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

    @Test func optedInVideoRetainsSourceAndPosterAcrossDeliveryReloadAndSecondDevelop() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_import_retained.mov", in: fixture.sources)
        var outputs: [URL] = []
        var saves: [URL] = []
        var durable: [RenderJob] = []
        // Storage sentinel only: actual JPEG decoding/bounds are covered by the
        // real ImageIO/AVAssetWriter receipt tests, not this queue fixture.
        let poster = Data([7, 8, 9])
        let queue = RenderQueueViewModel(render: { _ in
            let out = try fixture.movie("render_\(UUID().uuidString).mov", in: fixture.outputs)
            outputs.append(out)
            return out
        }, save: { saves.append($0) }, persist: { durable = $0 }, receipt: { _, _ in
            RenderReceipt(thumbnailJPEG: poster)
        }, mediaCleanup: fixture.cleaner)
        let id = try #require(queue.enqueueImportedVideo(sourceURL: source, stockId: "first", iso: 640,
            retainsDevelopmentSource: true, originalFilename: "ORIGINAL.MOV"))
        await settle(queue)
        #expect(queue.jobs.first?.status == .completed)
        #expect(queue.jobs.first?.hasRedevelopableSource == true)
        #expect(queue.jobs.first?.hasRedevelopableOriginal == false)
        #expect(queue.jobs.first?.permitsLocalMedia == false)
        #expect(queue.jobs.first?.shouldSaveOriginal == false)
        #expect(queue.jobs.first?.receipt?.thumbnailJPEG == poster)
        #expect(queue.jobs.first?.outputURL == nil)
        #expect(queue.jobs.first?.mediaCleanupCompleted == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(outputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(saves == outputs, "only developed outputs may be saved")
        let snapshot = try JSONDecoder().decode([RenderJob].self, from: JSONEncoder().encode(durable))
        let recovered = RenderQueueViewModel(render: { job in
            #expect(job.stockId == "second")
            #expect(job.iso == 640)
            let out = try fixture.movie("render_second.mov", in: fixture.outputs)
            outputs.append(out)
            return out
        }, save: { saves.append($0) }, persist: { durable = $0 }, load: { snapshot },
        receipt: { _, _ in RenderReceipt(thumbnailJPEG: poster) }, mediaCleanup: fixture.cleaner)
        recovered.onAppear()
        await settle(recovered)
        #expect(recovered.jobs.first?.receipt?.thumbnailJPEG == poster,
                "onAppear and persistence must preserve opted-in posters")
        let model = DevelopVideoModel(queue: recovered)
        await model.adoptExistingJobs(recovered.jobs)
        #expect(recovered.jobs.first?.status == .completed)
        #expect(model.sources.first?.originalFilename == "ORIGINAL.MOV")
        #expect(model.resultJobIDs.isEmpty)
        let stock = FilmStockConfig(stockId: "second", displayName: "Second", category: .video,
            lutName: "test.cube", halationStrength: 0.2, glowStrength: 0.1, grainSize: 1, defaultISO: 400)
        #expect(model.develop(stock: stock, iso: 100, gauge: .eightMillimetre,
                              pushPull: .manual(.pullOne)).queued == 1)
        #expect(model.resultJobIDs == [id])
        await settle(recovered)
        #expect(outputs.count == 2, "explicit second Develop must actually invoke the renderer")
        #expect(saves == outputs)
        #expect(FileManager.default.fileExists(atPath: source.path))
        recovered.remove(jobId: id)
        await settle(recovered)
        #expect(recovered.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(durable.isEmpty)
    }

    @Test func legacyImportedVideoStillStripsPosterAndCleansBothMovies() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_import_legacy.mov", in: fixture.sources)
        let output = try fixture.movie("render_legacy.mov", in: fixture.outputs)
        var durable: [RenderJob] = []
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in }, persist: { durable = $0 },
            receipt: { _, _ in RenderReceipt(thumbnailJPEG: Data([1])) }, mediaCleanup: fixture.cleaner)
        _ = queue.enqueueImportedVideo(sourceURL: source, stockId: "test", iso: 400)
        await settle(queue)
        #expect(queue.jobs.first?.retainsDevelopmentSource == nil)
        #expect(queue.jobs.first?.receipt?.thumbnailJPEG == nil)
        #expect(durable.first?.receipt?.thumbnailJPEG == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func failedRedevelopPersistenceRestoresRecipeOutputAndCaptureFields() throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_import_rollback.mov", in: fixture.sources)
        let output = try fixture.movie("render_rollback.mov", in: fixture.outputs)
        var job = RenderJob(sourceURL: source, stockId: "old", iso: 800,
                            pushPull: .automatic(meteredOffsetEV: 2))
        job.status = .completed
        job.outputURL = output
        job.outputSavedToPhotos = true
        job.isImportedVideo = true
        job.retainsDevelopmentSource = true
        job.receipt = RenderReceipt(thumbnailJPEG: Data([4]))
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in },
            persist: { _ in throw Failure.denied }, mediaCleanup: fixture.cleaner)
        queue.jobs = [job]
        #expect(queue.redevelopJobs(jobIds: [job.id], stockId: "new", gauge: .eightMillimetre,
                                    pushPull: .manual(.pushTwo)) == 0)
        #expect(queue.jobs == [job])
        #expect(queue.isPersistenceBlocked)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func explicitRetainedPhotoRemovalCleansRawAndEarlierSameStemJPEG() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("photo_import_remove.nef", in: fixture.sources)
        let output = try fixture.movie("photo_import_remove.jpg", in: fixture.sources)
        var job = RenderJob(sourceURL: source, stockId: "photo", iso: 400)
        job.isPhoto = true
        job.isImportedPhoto = true
        job.retainsDevelopmentSource = true
        job.status = .failed
        // A prior JPEG can exist even when a failed re-render has no outputURL.
        let queue = RenderQueueViewModel(render: { _ in output }, save: { _ in },
            persist: { _ in }, mediaCleanup: fixture.cleaner)
        queue.jobs = [job]
        queue.remove(jobId: job.id)
        await settle(queue)
        #expect(queue.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func completedRetainedSourceProtectsOtherJobsCleanup() async throws {
        let fixture = try ExportCleanupFixture()
        defer { fixture.remove() }
        let source = try fixture.movie("clip_shared_retained.mov", in: fixture.sources)
        var retained = RenderJob(sourceURL: source, stockId: "retained", iso: 400)
        retained.status = .completed
        retained.retainsDevelopmentSource = true
        retained.receipt = RenderReceipt()
        retained.outputSavedToPhotos = true
        retained.mediaCleanupCompleted = true
        var legacy = RenderJob(sourceURL: source, stockId: "legacy", iso: 400)
        legacy.status = .completed
        legacy.receipt = RenderReceipt()
        legacy.outputSavedToPhotos = true
        let snapshot = [retained, legacy]
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
            persist: { _ in }, load: { snapshot }, mediaCleanup: fixture.cleaner)
        queue.onAppear()
        await settle(queue)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(queue.jobs.last?.mediaCleanupCompleted != true)
        #expect(queue.jobs.last?.cleanupWarning != nil)
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
