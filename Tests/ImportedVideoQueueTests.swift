import Foundation
import Testing

@Suite(.serialized) @MainActor
struct ImportedVideoQueueTests {
    private enum Failure: Error { case render, save, persistence }

    private func files() throws -> (root: URL, source: URL, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("clip_import_fixture.mov")
        let output = root.appendingPathComponent("render_fixture.mov")
        // Queue state-machine fixtures only; encoded-media coverage is separate.
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: output)
        return (root, source, output)
    }

    private func settle(_ model: RenderQueueViewModel) async throws {
        for _ in 0..<300 {
            if !model.isProcessing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The imported-video queue did not settle.")
    }

    @Test func importedEnqueueOverridesOriginalDeliveryAndRequiresDurability() throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var snapshots: [[RenderJob]] = []
        let model = RenderQueueViewModel(render: { _ in f.output }, save: { _ in },
                                        persist: { snapshots.append($0) })
        model.renderAllowed = { false }
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400,
            preferences: .init(saveOriginalLog: true, quality: .smaller)))
        let job = try #require(model.jobs.first)
        #expect(job.id == id && job.isImportedVideo == true)
        #expect(job.deliveryPreferences?.saveOriginalLog == false)
        #expect(job.deliveryPreferences?.quality == .smaller)
        #expect(job.trimRange == nil && job.capturePolicy == nil && job.originalOnly != true)
        #expect(snapshots.first?.first?.id == id)
        #expect(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400) == id)
        #expect(model.jobs.count == 1)
    }

    @Test func failedPersistenceLeavesOwnershipWithTheImportSheet() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(render: { _ in renders += 1; return f.output },
            save: { _ in saves += 1 }, persist: { _ in throw Failure.persistence })
        #expect(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400) == nil)
        await Task.yield()
        #expect(model.jobs.isEmpty && renders == 0 && saves == 0)
        #expect(model.isPersistenceBlocked)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func successfulImportSavesOnlyOutputAndCleansOwnedFiles() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(render: { _ in f.output }, save: { saves.append($0) },
            persist: { _ in }, receipt: { _, _ in
                var result = RenderReceipt()
                result.thumbnailJPEG = Data([9])
                return result
            }, mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        _ = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        try await settle(model)
        #expect(saves == [f.output])
        let job = try #require(model.jobs.first)
        #expect(job.status == .completed && job.outputSavedToPhotos == true)
        #expect(job.sourceSavedToPhotos != true && job.receipt?.thumbnailJPEG == nil)
        #expect(job.mediaCleanupCompleted == true)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func renderFailureNeverExportsTheImportedOriginal() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(render: { _ in throw Failure.render },
                                        save: { saves.append($0) }, persist: { _ in })
        _ = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        try await settle(model)
        #expect(saves.isEmpty)
        #expect(model.jobs.first?.status == .failed)
        #expect(model.jobs.first?.sourceSavedToPhotos != true)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func failedOutputSaveRetriesTheSameRenderWithoutSavingOriginal() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(render: { _ in renders += 1; return f.output }, save: {
            saves.append($0)
            if saves.count == 1 { throw Failure.save }
        }, persist: { _ in }, receipt: { _, _ in RenderReceipt() })
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        try await settle(model)
        #expect(model.jobs.first?.status == .failed)
        model.retry(jobId: id)
        try await settle(model)
        #expect(renders == 1 && saves == [f.output, f.output])
        #expect(model.jobs.first?.status == .completed)
    }

    @Test func recoveryCannotExportAnImportedOriginalEvenWithConflictingLegacySettings() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var imported = RenderJob(sourceURL: f.source, stockId: "5219", iso: 400,
                                 deliveryPreferences: .init(saveOriginalLog: true))
        imported.isImportedVideo = true
        imported.originalOnly = true
        imported.status = .processing
        let snapshot = imported
        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(render: { _ in renders += 1; throw Failure.render },
            save: { saves.append($0) }, persist: { _ in }, load: { [snapshot] },
            journal: CaptureJournal(root: f.root.appendingPathComponent("Journal")))
        model.onAppear()
        try await settle(model)
        #expect(renders == 1 && saves.isEmpty)
        #expect(model.jobs.first?.isImportedVideo == true && model.jobs.first?.status == .failed)
        model.exportOriginal(jobId: imported.id)
        #expect(!model.enqueueOriginalOnly(sourceURL: f.source, reason: "recovered"))
        try await settle(model)
        #expect(saves.isEmpty && model.jobs.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func removingImportDiscardsItsOwnedMoviesAfterPersistingTheRequest() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var snapshots: [[RenderJob]] = []
        var removals: [URL] = []
        let model = RenderQueueViewModel(render: { _ in Issue.record("Discard must not render"); return f.output },
            save: { _ in Issue.record("Discard must not save to Photos") }, persist: { snapshots.append($0) },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root, remove: {
                #expect(snapshots.last?.first?.discardImportedMedia == true)
                removals.append($0)
                try FileManager.default.removeItem(at: $0)
            }))
        model.renderAllowed = { false }
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        model.jobs[0].outputURL = f.output
        model.remove(jobId: id)
        try await settle(model)
        #expect(model.jobs.isEmpty && snapshots.last?.isEmpty == true)
        #expect(Set(removals) == [f.source, f.output])
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func discardPersistenceFailureKeepsTheImportedJobAndFilesUntilResume() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var failPersistence = false
        let model = RenderQueueViewModel(render: { _ in Issue.record("Discard must not render"); return f.output },
            save: { _ in Issue.record("Discard must not save to Photos") },
            persist: { _ in if failPersistence { throw Failure.persistence } },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root))
        model.renderAllowed = { false }
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        failPersistence = true
        model.remove(jobId: id)
        try await settle(model)
        #expect(model.jobs.count == 1 && model.isPersistenceBlocked)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        failPersistence = false
        model.resume()
        try await settle(model)
        #expect(model.jobs.isEmpty && !model.isPersistenceBlocked)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func discardedImportRecoversAndRetriesCleanupWithoutRenderingOrSaving() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var imported = RenderJob(sourceURL: f.source, stockId: "5219", iso: 400)
        imported.isImportedVideo = true
        imported.discardImportedMedia = true
        imported.status = .failed
        let snapshot = imported
        var failCleanup = true
        var removals = 0
        let model = RenderQueueViewModel(render: { _ in Issue.record("Discard must not render"); return f.output },
            save: { _ in Issue.record("Discard must not save to Photos") }, persist: { _ in }, load: { [snapshot] },
            mediaCleanup: RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root, remove: {
                removals += 1
                if failCleanup { throw Failure.persistence }
                try FileManager.default.removeItem(at: $0)
            }), journal: CaptureJournal(root: f.root.appendingPathComponent("Journal")))
        model.onAppear()
        try await settle(model)
        #expect(model.jobs.count == 1 && model.jobs.first?.cleanupWarning != nil)
        #expect(removals == 1 && FileManager.default.fileExists(atPath: f.source.path))
        failCleanup = false
        model.retry(jobId: imported.id)
        try await settle(model)
        #expect(model.jobs.isEmpty && removals == 2)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func recoveryFinishesDiscardAfterFilesWereDeletedButFinalPersistenceFailed() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queueURL = f.root.appendingPathComponent("queue.json")
        let persister = QueuePersister(storageURL: queueURL)
        let cleanup = RenderMediaCleanup(sourceRoot: f.root, outputRoot: f.root)
        let model = RenderQueueViewModel(render: { _ in Issue.record("Discard must not render"); return f.output },
            save: { _ in Issue.record("Discard must not save to Photos") }, persist: {
                if $0.isEmpty { throw Failure.persistence }
                try persister.save($0)
            }, mediaCleanup: cleanup)
        model.renderAllowed = { false }
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400))
        model.remove(jobId: id)
        try await settle(model)
        #expect(model.isPersistenceBlocked && model.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try persister.load().first?.discardImportedMedia == true)
        let recovered = RenderQueueViewModel(persistenceURL: queueURL,
            render: { _ in Issue.record("Discard must not render"); return f.output },
            save: { _ in Issue.record("Discard must not save to Photos") }, mediaCleanup: cleanup,
            journal: CaptureJournal(root: f.root.appendingPathComponent("Journal")))
        recovered.onAppear()
        try await settle(recovered)
        #expect(recovered.jobs.isEmpty && !recovered.isPersistenceBlocked)
        #expect(try persister.load().isEmpty)
    }

    @Test func importedOriginSurvivesPersistenceAndLegacyJobsRemainCameraJobs() throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var imported = RenderJob(sourceURL: f.source, stockId: "5219", iso: 400)
        imported.isImportedVideo = true
        let recovered = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(imported))
        #expect(recovered.isImportedVideo == true && !recovered.permitsLocalMedia)
        let legacy = RenderJob(sourceURL: f.source, stockId: "5219", iso: 400)
        let recoveredLegacy = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(legacy))
        #expect(recoveredLegacy.isImportedVideo == nil && recoveredLegacy.permitsLocalMedia)
    }
}
