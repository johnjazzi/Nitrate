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

    @Test func keptOriginalIsQueuedOriginalOnlySavedUnchangedAndNeverRendered() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var rendered = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            rendered += 1
            return files.output
        }, save: { url in
            saves.append(url)
        })

        let accepted = model.enqueueOriginalOnly(sourceURL: files.source, reason: "1.30 s audio gap")

        #expect(accepted)
        try await waitUntil { !model.isProcessing }
        #expect(rendered == 0)
        #expect(saves == [files.source])
        // A kept original is a durable original-only queue entry, never rendered.
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.originalOnly == true)
        #expect(model.jobs.first?.status == .completed)
        #expect(model.externalErrorMessage == nil)
    }

    @Test func keptOriginalSaveFailureIsDurablyQueuedForRetry() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output },
                                         save: { _ in throw QueueTestError.save })

        let accepted = model.enqueueOriginalOnly(sourceURL: files.source, reason: "1.30 s audio gap")

        #expect(accepted)
        try await waitUntil { model.jobs.first?.status == .failed }
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.errorMessage?.contains("1.30 s audio gap") == true)
        #expect(model.jobs.first?.errorMessage?.contains("Photos") == true)
        #expect(model.jobs.first?.sourceSavedToPhotos == false)
    }

    @Test func keptOriginalThatIsGoneIsNotQueued() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output },
                                         save: { url in saves.append(url) })

        let accepted = model.enqueueOriginalOnly(
            sourceURL: files.directory.appendingPathComponent("missing.mov"),
            reason: "1.30 s audio gap")

        #expect(accepted == false)
        #expect(saves.isEmpty)
        #expect(model.jobs.isEmpty)
        #expect(model.externalErrorMessage?.contains("no longer available") == true)
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
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
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
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
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
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
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
            model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
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
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { model.jobs.first?.status == .failed }
        #expect(model.jobs.first?.outputURL == files.output)
        model.retry(jobId: try #require(model.jobs.first).id)
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 1)
        #expect(saves == 2)
        #expect(model.jobs.first?.outputSavedToPhotos == true)
    }

    @Test func completedDeliveryPersistsBeforePostDeliveryDiagnostics() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let gate = QueueTestGate()
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            return files.output
        }, save: { _ in
            saves += 1
        }, postDelivery: { _, _ in
            await gate.suspend()
        })

        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { saves == 1 && model.jobs.first?.outputSavedToPhotos == true }
        let reloaded = RenderQueueViewModel(persistenceURL: files.persistence,
                                            render: { _ in renders += 1; return files.output },
                                            save: { _ in saves += 1 }, sessionId: launchSession)
        reloaded.onAppear()
        #expect(reloaded.jobs.first?.status == .completed)
        #expect(reloaded.jobs.first?.outputSavedToPhotos == true)
        try await Task.sleep(for: .milliseconds(25))
        #expect(renders == 1)
        #expect(saves == 1)
        await gate.resume()
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

    @Test func dismissedFailureDoesNotReturnWhenLaterJobsPersistSuccessfully() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { job in
            if job.stockId == "A" { throw QueueTestError.render }
            return files.output
        }, save: { _ in }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "A", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        let failedID = try #require(model.jobs.first?.id)
        let failure = try #require(model.rendererErrorMessage)
        #expect(model.jobs.first?.status == .failed)

        model.dismissRendererError()
        model.enqueue(sourceURL: files.source, stockId: "B", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        #expect(model.rendererErrorMessage == nil)
        model.enqueue(sourceURL: files.source, stockId: "B", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        #expect(model.rendererErrorMessage == nil)
        #expect(model.jobs.first { $0.id == failedID }?.errorMessage == failure)
        #expect(model.currentSessionFailures.map(\.id) == [failedID])
        #expect(model.historyJobs.count == 3)
    }

    @Test func differentJobFailureWithIdenticalTextIsANewAlert() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in throw QueueTestError.render },
                                         save: { _ in }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "A", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        let firstMessage = try #require(model.rendererErrorMessage)
        model.dismissRendererError()
        model.enqueue(sourceURL: files.source, stockId: "C", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        #expect(model.jobs.count == 2)
        #expect(model.jobs[0].id != model.jobs[1].id)
        #expect(model.jobs.allSatisfy { $0.status == .failed })
        #expect(model.jobs[0].errorMessage == model.jobs[1].errorMessage)
        #expect(model.rendererErrorMessage == firstMessage)
    }

    @Test func retryFailureAnnouncesAgainAndKeepsTheFailedJob() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var attempts = 0
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            attempts += 1
            throw QueueTestError.render
        }, save: { _ in }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "A", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        let failedID = try #require(model.jobs.first?.id)
        #expect(model.rendererErrorMessage != nil)
        model.dismissRendererError()
        model.retry(jobId: failedID)
        try await waitUntil { !model.isProcessing }
        #expect(attempts == 2)
        #expect(model.rendererErrorMessage == model.jobs.first?.errorMessage)
        #expect(model.currentSessionFailures.map(\.id) == [failedID])
        #expect(model.historyJobs.map(\.id) == [failedID])
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
        #expect(loaded[0].deliveryPreferences == nil)
    }

    @Test func persistenceSaveFailurePausesBeforeRenderAndKeepsMediaFiles() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let blockedParent = files.directory.appendingPathComponent("not-a-directory")
        try Data([7]).write(to: blockedParent)
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(
            persistenceURL: blockedParent.appendingPathComponent("queue.json"),
            render: { _ in renders += 1; return files.output },
            save: { _ in saves += 1 }
        )
        let originalSource = try Data(contentsOf: files.source)
        let originalOutput = try Data(contentsOf: files.output)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        #expect(model.isPersistenceBlocked)
        #expect(model.rendererErrorMessage?.contains("Queue state could not be saved") == true)
        try await Task.sleep(for: .milliseconds(25))
        #expect(renders == 0)
        #expect(saves == 0)
        #expect(model.jobs.first?.status == .pending)
        #expect(try Data(contentsOf: files.source) == originalSource)
        #expect(try Data(contentsOf: files.output) == originalOutput)
    }

    @Test func dismissingAQueueFailureDoesNotSuppressIndependentAlerts() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in throw QueueTestError.render },
                                         save: { _ in }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "A", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { !model.isProcessing }
        model.dismissRendererError()
        #expect(model.rendererErrorMessage == nil)
        model.externalErrorMessage = "Stock library failed"
        #expect(model.rendererErrorMessage == "Stock library failed")
        model.dismissRendererError()
        model.externalErrorMessage = "Stock library failed"
        #expect(model.rendererErrorMessage == "Stock library failed")
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
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(try Data(contentsOf: files.persistence) == corruptData)
        #expect(model.rendererErrorMessage?.contains("Queue state could not be loaded") == true)
    }

    @Test(arguments: [false, true])
    func requestedDeliverySavesRenderedFirstAndWaitsForOriginal(saveOriginal: Bool) async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let gate = QueueTestGate()
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output }, save: { url in
            saves.append(url)
            if url == files.source { await gate.suspend() }
        }, postDelivery: { _, _ in })
        let preferences = RenderDeliveryPreferences(saveOriginalLog: saveOriginal)
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400, deliveryPreferences: preferences)
        if saveOriginal {
            try await waitUntil { saves.count == 2 }
            #expect(saves == [files.output, files.source])
            #expect(model.jobs.first?.status == .processing)
            #expect(model.jobs.first?.outputSavedToPhotos == true)
            #expect(model.jobs.first?.sourceSavedToPhotos != true)
            let persisted = try #require(try QueuePersister(storageURL: files.persistence).load().first)
            #expect(persisted.status == .processing)
            #expect(persisted.outputSavedToPhotos == true)
            await gate.resume()
        }
        try await waitUntil { !model.isProcessing }
        #expect(model.jobs.first?.status == .completed)
        #expect(saves == (saveOriginal ? [files.output, files.source] : [files.output]))
        #expect(model.jobs.first?.sourceSavedToPhotos == (saveOriginal ? true : nil))
        #expect(model.jobs.first?.outputSavedToPhotos == true)
        #expect(try Data(contentsOf: files.source) == Data([1, 2, 3]))
        let delivered = try #require(try QueuePersister(storageURL: files.persistence).load().first)
        #expect(delivered.status == .completed)
        #expect(delivered.sourceSavedToPhotos == (saveOriginal ? true : nil))
    }

    @Test(arguments: [false, true])
    func failedOriginalRetriesOnlyOriginalEvenWithoutRetainedOutput(removeOutput: Bool) async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var renders = 0
        var saves: [URL] = []
        var failOriginal = true
        // Use an isolated preferences domain rather than mutating shared defaults
        // while other Swift Testing suites run concurrently.
        let suiteName = "RenderQueueReliabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: DeliverySettings.saveOriginalLogKey)
        defaults.set(RenderExportQuality.smaller.rawValue, forKey: DeliverySettings.renderQualityKey)
        let preferences = DeliverySettings.renderPreferences(defaults: defaults)
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { job in
            renders += 1
            #expect(job.deliveryPreferences == preferences)
            return files.output
        }, save: { url in
            saves.append(url)
            if url == files.source && failOriginal { throw QueueTestError.save }
        }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400, deliveryPreferences: preferences)
        try await waitUntil { !model.isProcessing }
        let failed = try #require(model.jobs.first)
        #expect(failed.status == .failed)
        #expect(failed.outputSavedToPhotos == true)
        #expect(failed.sourceSavedToPhotos == false)
        #expect(failed.errorMessage?.contains("Rendered movie saved to Photos") == true)
        #expect(failed.outputURL == files.output)
        #expect(failed.sourceURL == files.source)
        let roundTrip = try #require(try QueuePersister(storageURL: files.persistence).load().first)
        #expect(roundTrip == failed)
        #expect(roundTrip.deliveryPreferences?.quality.averageBitRate == 30_000_000)
        if removeOutput { try FileManager.default.removeItem(at: files.output) }
        defaults.set(false, forKey: DeliverySettings.saveOriginalLogKey)
        defaults.set(RenderExportQuality.high.rawValue, forKey: DeliverySettings.renderQualityKey)
        #expect(DeliverySettings.renderPreferences(defaults: defaults) == RenderDeliveryPreferences())
        failOriginal = false
        model.retry(jobId: failed.id)
        try await waitUntil { !model.isProcessing }
        #expect(model.jobs.first?.status == .completed)
        #expect(model.jobs.first?.outputSavedToPhotos == true)
        #expect(model.jobs.first?.sourceSavedToPhotos == true)
        #expect(model.jobs.first?.outputURL == files.output)
        #expect(model.jobs.first?.deliveryPreferences == preferences)
        #expect(renders == 1)
        #expect(saves == [files.output, files.source, files.source])
    }

    @Test func outputSaveFailureDoesNotAttemptRequestedOriginal() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output }, save: { url in
            saves.append(url)
            throw QueueTestError.save
        }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences(saveOriginalLog: true))
        try await waitUntil { !model.isProcessing }
        #expect(saves == [files.output])
        #expect(model.jobs.first?.status == .failed)
        #expect(model.jobs.first?.outputSavedToPhotos == false)
        #expect(model.jobs.first?.sourceSavedToPhotos == nil)
        #expect(model.jobs.first?.errorMessage?.contains("Photos save failed") == true)
    }

    @Test(arguments: [false, true])
    func renderFallbackRemainsEnabledAndRetryDoesNotDuplicateOriginal(saveOriginal: Bool) async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var renders = 0
        var saves: [URL] = []
        let preferences = RenderDeliveryPreferences(saveOriginalLog: saveOriginal, quality: .smaller)
        let model = RenderQueueViewModel(persistenceURL: files.persistence, render: { job in
            renders += 1
            #expect(job.deliveryPreferences == preferences)
            if renders < 3 { throw QueueTestError.render }
            return files.output
        }, save: { saves.append($0) }, postDelivery: { _, _ in })
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400, deliveryPreferences: preferences)
        try await waitUntil { !model.isProcessing }
        let id = try #require(model.jobs.first?.id)
        #expect(model.jobs.first?.sourceSavedToPhotos == true)
        #expect(model.jobs.first?.status == .failed)
        model.retry(jobId: id)
        try await waitUntil { !model.isProcessing }
        #expect(saves == [files.source])
        #expect(model.jobs.first?.errorMessage?.contains("already saved") == true)
        model.retry(jobId: id)
        try await waitUntil { !model.isProcessing }
        #expect(model.jobs.first?.status == .completed)
        #expect(model.jobs.first?.sourceSavedToPhotos == true)
        #expect(model.jobs.first?.deliveryPreferences == preferences)
        #expect(saves == [files.source, files.output])
    }

    @Test(arguments: [false, true])
    func restoredConfirmedOutputNeedsOnlyOriginal(hasOutputURL: Bool) async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let preferences = RenderDeliveryPreferences(saveOriginalLog: true, quality: .smaller)
        var interrupted = RenderJob(sourceURL: files.source, stockId: "test", iso: 400,
                                    deliveryPreferences: preferences)
        interrupted.status = .processing
        interrupted.outputURL = hasOutputURL ? files.output : nil
        interrupted.outputSavedToPhotos = true
        try QueuePersister(storageURL: files.persistence).save([interrupted])
        var saves: [URL] = []
        var renders = 0
        let restored = RenderQueueViewModel(persistenceURL: files.persistence, render: { _ in
            renders += 1
            throw QueueTestError.render
        }, save: { saves.append($0) }, postDelivery: { _, _ in })
        restored.onAppear()
        try await waitUntil { !restored.isProcessing }
        #expect(restored.jobs.first?.status == .completed)
        #expect(restored.jobs.first?.outputSavedToPhotos == true)
        #expect(restored.jobs.first?.sourceSavedToPhotos == true)
        #expect(restored.jobs.first?.deliveryPreferences == preferences)
        #expect(renders == 0)
        #expect(saves == [files.source])
    }

    @Test func legacyJobWithoutPreferencesDeliversRenderedOnly() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let legacy = RenderJob(sourceURL: files.source, stockId: "test", iso: 400)
        try QueuePersister(storageURL: files.persistence).save([legacy])
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output }, save: { saves.append($0) },
                                         postDelivery: { _, _ in })
        model.onAppear()
        try await waitUntil { !model.isProcessing }
        #expect(model.jobs.first?.status == .completed)
        #expect(model.jobs.first?.deliveryPreferences == nil)
        #expect(saves == [files.output])
    }

    @Test func oneUnreadablePersistedJobDoesNotDiscardTheQueue() throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let valid = RenderJob(sourceURL: files.source, stockId: "keep", iso: 400,
                              printGauge: .thirtyFiveMillimetre)
        let encoded = try JSONEncoder().encode([valid])
        var jobs = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

        // A job written before the gauge labels were shortened, and a wholly
        // malformed entry: neither may take the readable job down with it.
        var legacy = jobs[0]
        legacy["printGauge"] = "thirtyFiveMillimetre"
        var malformed = jobs[0]
        malformed["iso"] = "not-a-number"
        let data = try JSONSerialization.data(withJSONObject: [legacy, malformed])
        try data.write(to: files.persistence)

        let loaded = try QueuePersister(storageURL: files.persistence).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.stockId == "keep")
        // The legacy long-form value still resolves to the same gauge.
        #expect(loaded.first?.printGauge == .thirtyFiveMillimetre)
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
