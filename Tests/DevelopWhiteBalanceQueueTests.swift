import Foundation
import Testing

/// Develop's manual white balance is a durable recipe value, not a live
/// preference. These tests measure it at the queue's own seams: what a legacy
/// queue file decodes to, what an accepted job freezes, what survives a retry,
/// a relaunch and a re-develop, and what a failed write rolls back.
///
/// The shared `DevelopWhiteBalance` type is owned elsewhere; this file only
/// consumes it.
@Suite(.serialized) @MainActor
struct DevelopWhiteBalanceQueueTests {
    private enum Failure: Error { case render, persistence }

    private struct Fixture {
        let root: URL
        let persistence: URL
        let source: URL
        let output: URL
    }

    // MARK: - Fixtures

    private func fixture(extension ext: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("photo_import_\(UUID().uuidString).\(ext)")
        let output = root.appendingPathComponent("develop_out.\(ext == "dng" ? "jpg" : "mov")")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: output)
        return Fixture(root: root, persistence: root.appendingPathComponent("queue.json"),
                       source: source, output: output)
    }

    /// A render that really writes a file, because the queue rejects an output
    /// it cannot stat. Each call gets its own path so a re-develop cannot pass
    /// by reusing the previous result.
    private func renderInto(_ fixture: Fixture) -> RenderQueueViewModel.RenderOperation {
        { _ in
            let url = fixture.root.appendingPathComponent("out-\(UUID().uuidString).jpg")
            try Data([7]).write(to: url)
            return url
        }
    }

    private func queue(_ fixture: Fixture,
                       render: @escaping RenderQueueViewModel.RenderOperation,
                       persist: (([RenderJob]) throws -> Void)? = nil) -> RenderQueueViewModel {
        RenderQueueViewModel(persistenceURL: fixture.persistence, render: render, save: { _ in },
                             persist: persist, receipt: { _, _ in RenderReceipt() })
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the queue to settle.")
    }

    private func settled(_ queue: RenderQueueViewModel, _ id: UUID,
                         status: RenderJob.JobStatus = .completed) async throws {
        try await Self.wait { queue.jobs.first { $0.id == id }?.status == status && !queue.isProcessing }
    }

    // MARK: - Legacy records

    @Test func queueWrittenBeforeDevelopDecodesWithoutARecipeAndRendersNeutral() throws {
        var legacy = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/legacy_take.mov"),
                               stockId: "5219", iso: 400)
        legacy.status = .completed
        let encoded = try JSONEncoder().encode([legacy])
        // A nil recipe is not written at all, which is exactly the shape of a
        // queue file produced before Develop knew about white balance.
        var objects = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(objects.first?["developmentWhiteBalance"] == nil,
                "a job without a recipe must not gain a key the old build cannot read")

        // Counter-check: a job that DOES carry a recipe writes one, so the
        // absence above is a real absence and not a broken encoder.
        var balanced = legacy
        balanced.developmentWhiteBalance = DevelopWhiteBalance(photoKelvin: 5_000)
        let balancedJSON = try #require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode([balanced])) as? [[String: Any]])
        #expect(balancedJSON.first?["developmentWhiteBalance"] != nil,
                "an accepted recipe is persisted")
        let roundTripped = try #require(JSONDecoder().decode([RenderJob].self,
            from: try JSONEncoder().encode([balanced])).first)
        #expect(roundTripped.developmentWhiteBalance == DevelopWhiteBalance(photoKelvin: 5_000))

        objects[0].removeValue(forKey: "developmentWhiteBalance")
        let legacyData = try JSONSerialization.data(withJSONObject: objects)

        let decoded = try JSONDecoder().decode([RenderJob].self, from: legacyData)
        let restored = try #require(decoded.first)
        #expect(restored.developmentWhiteBalance == nil, "absent means absent, not a fabricated value")
        // The render seam is the one place nil is interpreted, and it means the
        // stock's own balance.
        #expect((restored.developmentWhiteBalance ?? .neutral) == .neutral)
    }

    @Test func malformedWhiteBalanceFieldPreservesTheJobWithNeutralAdjustment() throws {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/one.mov"), stockId: "5219", iso: 400)
        job.status = .completed
        var payload = try #require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode([job])) as? [[String: Any]])
        payload[0]["developmentWhiteBalance"] = ["photoKelvin": "warm"]
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        try JSONSerialization.data(withJSONObject: payload).write(to: storage)
        let restored = try QueuePersister(storageURL: storage).load()
        #expect(restored.count == 1, "a malformed optional adjustment must not discard the original job")
        #expect(restored.first?.developmentWhiteBalance == .neutral)
    }

    @Test func malformedWholeRecipeDoesNotDiscardAQueueJob() throws {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/fixture/source.mov"), stockId: "5219", iso: 400)
        job.status = .completed
        var payload = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode([job])) as? [[String: Any]])
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-malformed-whole-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        for malformed: Any in ["warm", 42, [1, 2]] {
            payload[0]["developmentWhiteBalance"] = malformed
            try JSONSerialization.data(withJSONObject: payload).write(to: storage)
            let jobs = try QueuePersister(storageURL: storage).load()
            #expect(jobs.count == 1, "Optional WB corruption must not discard the retained-source job")
            #expect(jobs.first?.id == job.id)
            #expect(jobs.first?.developmentWhiteBalance == .neutral)
        }
    }

    // MARK: - Freeze, retry, relaunch

    @Test func acceptedJobFreezesManualWhiteBalanceThroughFailureRetryAndRelaunch() async throws {
        let f = try fixture(extension: "dng")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let manual = DevelopWhiteBalance(photoKelvin: 5_600)
        var attempts = 0
        let writing = renderInto(f)
        let model = queue(f, render: { job in
            attempts += 1
            if attempts == 1 { throw Failure.render }
            return try await writing(job)
        })
        let id = try #require(model.enqueuePhoto(sourceURL: f.source, stockId: "kodak5207", iso: 250,
                                                 gauge: .neutral, cropZoom: 1, seed: 9,
                                                 isImported: true, whiteBalance: manual))
        try await settled(model, id, status: .failed)
        #expect(model.jobs.first?.developmentWhiteBalance == manual,
                "the recipe is frozen at acceptance, not read again at render time")

        model.retry(jobId: id)
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == manual, "a retry keeps the accepted recipe")

        // Relaunch: the same record, read back through the real persister.
        let relaunched = queue(f, render: renderInto(f))
        relaunched.onAppear()
        let restored = try #require(relaunched.jobs.first { $0.id == id })
        #expect(restored.status == .completed)
        #expect(restored.developmentWhiteBalance == manual, "the recipe is durable, not session state")
    }

    @Test func importedVideoFreezesWarmthIndependentlyOfLaterPanelEdits() async throws {
        let f = try fixture(extension: "mov")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let warmth = DevelopWhiteBalance(videoWarmth: 0.65)
        let model = queue(f, render: renderInto(f))
        let id = try #require(model.enqueueImportedVideo(sourceURL: f.source, stockId: "5219", iso: 400,
                                                         retainsDevelopmentSource: true,
                                                         originalFilename: f.source.lastPathComponent,
                                                         whiteBalance: warmth))
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == warmth)

        let relaunched = queue(f, render: renderInto(f))
        relaunched.onAppear()
        #expect(relaunched.jobs.first?.developmentWhiteBalance == warmth)
    }

    // MARK: - Retained re-development

    @Test func retainedRedevelopUpdatesTheRecipeAndExplicitNeutralResetsIt() async throws {
        let f = try fixture(extension: "dng")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = queue(f, render: renderInto(f))
        let id = try #require(model.enqueuePhoto(sourceURL: f.source, stockId: "kodak5207", iso: 250,
                                                 gauge: .neutral, cropZoom: 1, seed: 3,
                                                 isImported: true,
                                                 whiteBalance: DevelopWhiteBalance(photoKelvin: 5_600)))
        try await settled(model, id)

        // A new manual balance is a real recipe edit.
        #expect(model.redevelopJobs(jobIds: [id], gauge: .eightMillimetre,
                                    whiteBalance: DevelopWhiteBalance(photoKelvin: 3_200)) == 1)
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == DevelopWhiteBalance(photoKelvin: 3_200))
        #expect(model.jobs.first?.printGauge == .eightMillimetre)

        // Omitting it preserves the shot's balance: a gauge-only edit must not
        // silently re-balance the photograph.
        #expect(model.redevelopJobs(jobIds: [id], gauge: .neutral) == 1)
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == DevelopWhiteBalance(photoKelvin: 3_200),
                "an omitted recipe preserves what the job already froze")

        // An explicit neutral is a reset request, not a no-op.
        #expect(model.redevelopJobs(jobIds: [id], whiteBalance: .neutral) == 1)
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == .neutral)
    }

    @Test func failedPersistOnRedevelopRollsTheWholeRecipeBack() async throws {
        let f = try fixture(extension: "dng")
        defer { try? FileManager.default.removeItem(at: f.root) }
        final class WriteGate { var rejects = false }
        let gate = WriteGate()
        let model = queue(f, render: renderInto(f), persist: { _ in
            if gate.rejects { throw Failure.persistence }
        })
        let original = DevelopWhiteBalance(photoKelvin: 5_600)
        let id = try #require(model.enqueuePhoto(sourceURL: f.source, stockId: "kodak5207", iso: 250,
                                                 gauge: .neutral, cropZoom: 1, seed: 5,
                                                 isImported: true, whiteBalance: original))
        try await settled(model, id)
        let before = model.jobs

        gate.rejects = true
        #expect(model.redevelopJobs(jobIds: [id], gauge: .eightMillimetre,
                                    whiteBalance: DevelopWhiteBalance(photoKelvin: 9_000)) == 0)
        #expect(model.isPersistenceBlocked)
        #expect(model.jobs == before, "a rejected write leaves the accepted recipe and result intact")
        #expect(model.jobs.first?.developmentWhiteBalance == original)
        #expect(model.jobs.first?.printGauge == .neutral)
        #expect(model.jobs.first?.status == .completed)

        gate.rejects = false
        model.resume()
        #expect(model.redevelopJobs(jobIds: [id], whiteBalance: .neutral) == 1)
        try await settled(model, id)
        #expect(model.jobs.first?.developmentWhiteBalance == .neutral)
    }

    // MARK: - Original-delivery policy is unchanged

    @Test func whiteBalanceDoesNotChangeImportedOriginalPolicy() async throws {
        let f = try fixture(extension: "mov")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: f.persistence,
                                        render: { _ in f.output }, save: { saves.append($0) },
                                        receipt: { _, _ in RenderReceipt() })
        let id = try #require(model.enqueueImportedVideo(
            sourceURL: f.source, stockId: "5219", iso: 400,
            preferences: .init(saveOriginalLog: true), retainsDevelopmentSource: true,
            originalFilename: f.source.lastPathComponent,
            whiteBalance: DevelopWhiteBalance(videoWarmth: -0.4)))
        let job = try #require(model.jobs.first { $0.id == id })
        #expect(job.developmentWhiteBalance == DevelopWhiteBalance(videoWarmth: -0.4))
        #expect(job.isImportedVideo == true)
        #expect(job.shouldSaveOriginal == false, "an imported original still never exports")
        #expect(job.permitsLocalMedia == false, "receipt playback policy is untouched")
        #expect(job.permitsReceiptPreview == true, "the retained develop source still previews")

        try await settled(model, id)
        #expect(saves == [f.output], "only the develop is delivered")
        #expect(model.jobs.first?.sourceSavedToPhotos != true)

        // A non-retained import keeps the stricter policy.
        let other = try fixture(extension: "mov")
        defer { try? FileManager.default.removeItem(at: other.root) }
        let bare = queue(other, render: { _ in other.output })
        _ = try #require(bare.enqueueImportedVideo(sourceURL: other.source, stockId: "5219", iso: 400,
                                                   whiteBalance: DevelopWhiteBalance(videoWarmth: 0.9)))
        let strict = try #require(bare.jobs.first)
        #expect(strict.permitsLocalMedia == false)
        #expect(strict.permitsReceiptPreview == false)
        #expect(strict.shouldSaveOriginal == false)
    }

    @Test func whiteBalanceDoesNotChangeImportedPhotoPolicy() async throws {
        let f = try fixture(extension: "dng")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = queue(f, render: renderInto(f))
        let id = try #require(model.enqueuePhoto(sourceURL: f.source, stockId: "kodak5207", iso: 250,
                                                 gauge: .neutral, cropZoom: 1, seed: 11,
                                                 preferences: .init(saveOriginalRAWToPhotos: true),
                                                 isImported: true,
                                                 whiteBalance: DevelopWhiteBalance(photoKelvin: 4_000)))
        try await settled(model, id)
        let job = try #require(model.jobs.first { $0.id == id })
        #expect(job.developmentWhiteBalance == DevelopWhiteBalance(photoKelvin: 4_000))
        #expect(job.shouldSaveOriginal == false, "an imported RAW is never re-delivered as an original")
        #expect(job.permitsLocalMedia)
        #expect(job.permitsReceiptPreview)
    }

    // MARK: - The Develop panel's recipe reaches the job

    @Test func developPanelPassesManualWhiteBalanceAcrossTheSameLease() async throws {
        let f = try fixture(extension: "mov")
        defer { try? FileManager.default.removeItem(at: f.root) }
        var seen: [Float] = []
        let queue = RenderQueueViewModel(persistenceURL: f.persistence, render: { job in
            // The render sees exactly what the job froze — the lease's original
            // file, unchanged, plus the panel's balance.
            #expect(job.sourceURL.standardizedFileURL == f.source.standardizedFileURL)
            seen.append(job.developmentWhiteBalance?.videoWarmth ?? 0)
            let url = f.root.appendingPathComponent("out-\(UUID().uuidString).mov")
            try Data([8]).write(to: url)
            return url
        }, save: { _ in }, receipt: { _, _ in RenderReceipt() })
        let model = DevelopVideoModel(queue: queue, inspect: { url, name in
            ImportedVideo(url: url, originalFilename: name, durationSeconds: 1.5,
                          pixelWidth: 1920, pixelHeight: 1080, nominalFrameRate: 30)
        })
        let stock = FilmStockConfig(stockId: "test", displayName: "Test", category: .video,
                                    lutName: "test.cube", halationStrength: 0.2, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 400)
        model.select(transfer: {
            DevelopClipTransfer(lease: VideoImportFileLease(url: f.source, directory: f.root),
                                originalFilename: f.source.lastPathComponent)
        })
        try await Self.wait { model.video != nil }

        let manual = DevelopWhiteBalance(videoWarmth: 0.7)
        #expect(model.develop(stock: stock, iso: 400, gauge: .neutral, pushPull: .neutral,
                              whiteBalance: manual).queued == 1)
        let id = try #require(model.activeJobID)
        try await settled(queue, id)
        #expect(seen == [0.7], "the manual balance was handed to the renderer, not dropped at the seam")
        #expect(queue.jobs.first?.developmentWhiteBalance == manual)
        #expect(queue.jobs.first?.sourceURL.standardizedFileURL == f.source.standardizedFileURL)

        // Re-developing the same retained original with an explicit reset stores
        // neutral on that same job — no duplicate entry, same lease.
        await model.adoptExistingJobs(queue.jobs)
        #expect(model.sources.count == 1)
        #expect(model.develop(stock: stock, iso: 400, gauge: .neutral, pushPull: .neutral,
                              whiteBalance: .neutral).queued == 1)
        try await Self.wait {
            queue.jobs.first?.status == .completed && queue.jobs.first?.developmentWhiteBalance == .neutral
                && !queue.isProcessing
        }
        #expect(queue.jobs.count == 1, "a reset re-develops the same job")
        #expect(queue.jobs.first?.sourceURL.standardizedFileURL == f.source.standardizedFileURL)
        #expect(seen.count == 2 && seen.last == 0)
    }
}
