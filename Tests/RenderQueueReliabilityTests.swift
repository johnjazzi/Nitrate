import Foundation
import Testing

@Suite("Render queue reliability", .serialized)
@MainActor
struct RenderQueueReliabilityTests {
    private let launchSession = "this-launch"
    private func scratch() throws -> (directory: URL, source: URL, output: URL, persistence: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("rendered.mov")
        try Data([1, 2, 3]).write(to: source)
        return (directory, source, output, directory.appendingPathComponent("queue.json"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for queue state")
    }

    @Test func suspendedWorkSerializesJobsAndRemovalUsesIdentity() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let gate = QueueTestGate()
        var active = 0
        var maximumActive = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            active += 1
            maximumActive = max(maximumActive, active)
            await gate.suspend()
            active -= 1
            return files.output
        }, save: { _ in
            active += 1
            maximumActive = max(maximumActive, active)
            active -= 1
        })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try #require(model.jobs.count == 2)
        let activeID = model.jobs[0].id
        let pendingID = model.jobs[1].id
        try await waitUntil { model.jobs.first?.status == .processing }
        try await waitUntil { active == 1 }
        model.remove(jobId: pendingID)
        await gate.resume()
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].id == activeID)
        #expect(maximumActive == 1)
    }

    @Test func secondJobWaitsForFirstPhotosDelivery() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let gate = QueueTestGate()
        var renders = 0
        var saves = 0
        var active = 0
        var maximumActive = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            active += 1
            maximumActive = max(maximumActive, active)
            active -= 1
            return files.output
        }, save: { _ in
            saves += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if saves == 1 { await gate.suspend() }
            active -= 1
        })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try await waitUntil { saves == 1 }
        #expect(model.jobs.map(\.status) == [.processing, .pending])
        #expect(renders == 1)
        #expect(maximumActive == 1)
        await gate.resume()
        try await waitUntil { model.jobs.allSatisfy { $0.status == .completed } }
        #expect(renders == 2)
        #expect(saves == 2)
        #expect(maximumActive == 1)
    }

    @Test func unavailableRendererFallbackUsesTheSerialWorker() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let gate = QueueTestGate()
        var saves = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            throw RenderQueueViewModel.QueueError.rendererUnavailable("Metal pipeline unavailable")
        }, save: { _ in
            saves += 1
            if saves == 1 { await gate.suspend() }
        })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try await waitUntil { saves == 1 }
        let firstID = try #require(model.jobs.first?.id)
        #expect(model.jobs.map(\.status) == [.processing, .pending])
        model.retry(jobId: firstID)
        #expect(model.jobs.first?.status == .processing)
        #expect(saves == 1)
        await gate.resume()
        try await waitUntil { model.jobs.allSatisfy { $0.status == .failed } }
        #expect(saves == 2)
        #expect(model.renderingUnavailableMessage == "Metal pipeline unavailable")
        #expect(model.rendererErrorMessage?.contains("Original Apple Log saved to Photos") == true)
    }

    @Test func failedRenderReportsSuccessfulOrFailedOriginalSave() async throws {
        for saveSucceeds in [true, false] {
            let files = try scratch()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            try Data([4, 5, 6]).write(to: files.output)
            let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
                throw QueueTestError.render
            }, save: { _ in
                if !saveSucceeds { throw QueueTestError.save }
            })
            model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
            try await waitUntil { model.jobs.first?.status == .failed && model.jobs.first?.sourceSavedToPhotos != nil }
            let job = try #require(model.jobs.first)
            #expect(job.sourceSavedToPhotos == saveSucceeds)
            if saveSucceeds {
                #expect(job.errorMessage?.contains("Original Apple Log saved to Photos") == true)
            } else {
                #expect(job.errorMessage?.contains("could not be saved to Photos") == true)
                #expect(job.errorMessage?.contains("Source remains in the app") == true)
            }
        }
    }

    @Test func failedOutputDeliveryRetriesWithoutRenderingAgain() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            return files.output
        }, save: { _ in
            saves += 1
            if saves == 1 { throw QueueTestError.save }
        })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try await waitUntil { model.jobs.first?.status == .failed }
        #expect(model.jobs.first?.outputURL == files.output)
        model.retry(jobId: try #require(model.jobs.first).id)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 1)
        #expect(saves == 2)
        #expect(model.jobs.first?.outputSavedToPhotos == true)
    }

    @Test func processingJobsRecoverAndRepeatedAppearanceIsIdempotent() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var original = RenderJob(sourceURL: files.source, stockId: "test", iso: 400)
        original.status = .processing
        try QueuePersister(storageURL: files.persistence).save([original])
        var renders = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            return files.output
        }, save: { _ in }, sessionId: launchSession)
        model.onAppear()
        model.onAppear()
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 1)
        #expect(model.jobs.first?.id == original.id)
        #expect(model.jobs.first?.sessionId == launchSession)
    }

    @Test func terminalHistoryScopesToLaunchAndSortsMixedStatusesNewestFirst() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var oldSuccess = RenderJob(sourceURL: files.source, stockId: "old", iso: 400,
                                   sessionId: "previous", createdAt: Date(timeIntervalSince1970: 10))
        oldSuccess.status = .completed
        var oldPending = RenderJob(sourceURL: files.source, stockId: "pending", iso: 400,
                                   sessionId: "previous", createdAt: Date(timeIntervalSince1970: 15))
        oldPending.status = .pending
        var currentFailure = RenderJob(sourceURL: files.source, stockId: "failed", iso: 400,
                                       sessionId: launchSession, createdAt: Date(timeIntervalSince1970: 20))
        currentFailure.status = .failed
        var currentSuccess = RenderJob(sourceURL: files.source, stockId: "newest", iso: 400,
                                       sessionId: launchSession, createdAt: Date(timeIntervalSince1970: 30))
        currentSuccess.status = .completed
        try QueuePersister(storageURL: files.persistence).save([oldSuccess, oldPending, currentFailure, currentSuccess])

        let gate = QueueTestGate()
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            await gate.suspend()
            return files.output
        }, save: { _ in }, sessionId: launchSession)
        model.onAppear()
        #expect(model.currentSessionResults.map(\.stockId) == ["newest", "failed"])
        #expect(model.historyJobs.map(\.stockId) == ["newest", "failed", "old"])
        #expect(model.outstandingJobs.map(\.stockId) == ["pending"])
        try Data([4, 5, 6]).write(to: files.output)
        await gate.resume()
        try await waitUntil { model.outstandingJobs.isEmpty }
        #expect(model.currentSessionResults.contains { $0.id == oldPending.id })
    }

    @Test func retryMovesHistoricalFailureIntoCurrentSession() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var historical = RenderJob(sourceURL: files.source, stockId: "old", iso: 400, sessionId: "previous")
        historical.status = .failed
        try QueuePersister(storageURL: files.persistence).save([historical])
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output },
                                         save: { _ in }, sessionId: launchSession)
        model.onAppear()
        model.retry(jobId: historical.id)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(model.jobs.first?.sessionId == launchSession)
        #expect(model.currentSessionResults.map(\.id) == [historical.id])
    }

    @Test func historicalFailureDoesNotSetCurrentLaunchBanner() throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var historical = RenderJob(sourceURL: files.source, stockId: "old", iso: 400, sessionId: "previous")
        historical.status = .failed
        historical.errorMessage = "old failure"
        try QueuePersister(storageURL: files.persistence).save([historical])
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output },
                                         save: { _ in }, sessionId: launchSession)
        model.onAppear()
        #expect(model.currentSessionFailures.isEmpty)
        #expect(model.rendererErrorMessage == nil)
        #expect(model.historyJobs.count == 1)
    }

    @Test func successfulRetryClearsCurrentSessionFailureBanner() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var failed = RenderJob(sourceURL: files.source, stockId: "test", iso: 400, sessionId: launchSession)
        failed.status = .failed
        failed.errorMessage = "Photos unavailable"
        try QueuePersister(storageURL: files.persistence).save([failed])
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in files.output },
                                         save: { _ in }, sessionId: launchSession)
        model.onAppear()
        model.externalErrorMessage = "Stock library failed"
        model.retry(jobId: failed.id)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(model.rendererErrorMessage == "Stock library failed")
        model.externalErrorMessage = nil
        model.remove(jobId: failed.id)
        #expect(model.rendererErrorMessage == nil)
        #expect(model.currentSessionFailures.isEmpty)
    }

    @Test func oldQueueJsonWithoutDeliveryFieldsStillDecodes() throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let oldJSON = """
        [{"id":"\(UUID().uuidString)","sourceURL":"\(files.source.absoluteString)","stockId":"test","iso":400,"createdAt":0,"sessionId":"legacy","status":"pending"}]
        """
        try Data(oldJSON.utf8).write(to: files.persistence)
        let loaded = try QueuePersister(storageURL: files.persistence).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].sourceSavedToPhotos == nil)
        #expect(loaded[0].outputSavedToPhotos == nil)
    }

    @Test func persistenceSaveFailureIsVisibleAndKeepsMediaFiles() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let blockedParent = files.directory.appendingPathComponent("not-a-directory")
        try Data([7]).write(to: blockedParent)
        let model = RenderQueueViewModel(
            persistenceURL: blockedParent.appendingPathComponent("queue.json"),
            render: { _ in files.output },
            save: { _ in }
        )
        let originalSource = try Data(contentsOf: files.source)
        let originalOutput = try Data(contentsOf: files.output)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(model.rendererErrorMessage?.contains("Queue state could not be saved") == true)
        #expect(try Data(contentsOf: files.source) == originalSource)
        #expect(try Data(contentsOf: files.output) == originalOutput)
    }

    @Test func corruptQueueLoadReportsErrorWithoutOverwritingFile() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let corruptData = Data("{ definitely not queue JSON".utf8)
        try corruptData.write(to: files.persistence)
        try Data([4, 5, 6]).write(to: files.output)
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in files.output },
            save: { _ in }
        )
        model.externalErrorMessage = "Stock library failed to load."
        #expect(model.rendererErrorMessage == "Stock library failed to load.")
        model.onAppear()
        #expect(model.jobs.isEmpty)
        #expect(model.rendererErrorMessage?.contains("Queue state could not be loaded") == true)
        #expect(try Data(contentsOf: files.persistence) == corruptData)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(try Data(contentsOf: files.persistence) == corruptData)
        #expect(model.rendererErrorMessage?.contains("Queue state could not be loaded") == true)
    }
}

private enum QueueTestError: Error, LocalizedError {
    case render, save
    var errorDescription: String? {
        switch self {
        case .render: "render broke"
        case .save: "Photos unavailable"
        }
    }
}

private actor QueueTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func suspend() async {
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
