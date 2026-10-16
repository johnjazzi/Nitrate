import Foundation
import Testing

/// Durability and recovery regressions for L03–L06.
///
/// L03: a failed durable transition must pause rendering/Photos side effects and
/// preserve media, with an explicit resume path (no exact-once crash claim).
/// L04: a take captured with no stock is durably queued awaiting a stock.
/// L05: a validation-failed kept original is durably queued original-only.
/// L06: production renders must not dump frame PNGs; injected post-delivery
///      diagnostics are preserved.
@Suite("Render queue recovery", .serialized)
@MainActor
struct RenderQueueRecoveryTests {
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
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for queue state")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - L03 durable transitions

    @Test func enqueuePersistenceFailurePausesBeforeRenderAndPhotos() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        // A file where a directory is expected makes every write fail.
        let blockedParent = files.directory.appendingPathComponent("not-a-directory")
        try Data([7]).write(to: blockedParent)
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(
            persistenceURL: blockedParent.appendingPathComponent("queue.json"),
            render: { _ in renders += 1; return files.output },
            save: { _ in saves += 1 },
            postDelivery: { _, _ in }
        )
        let originalSource = try Data(contentsOf: files.source)
        let originalOutput = try Data(contentsOf: files.output)

        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())

        #expect(model.isPersistenceBlocked)
        #expect(model.rendererErrorMessage?.contains("Queue state could not be saved") == true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(renders == 0)
        #expect(saves == 0)
        #expect(model.jobs.first?.status == .pending)
        #expect(try Data(contentsOf: files.source) == originalSource)
        #expect(try Data(contentsOf: files.output) == originalOutput)
    }

    @Test func resumeAfterDurableWriteFailureCompletesTheQueuedJob() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        let laterDirectory = files.directory.appendingPathComponent("later")
        let persistence = laterDirectory.appendingPathComponent("queue.json")
        var renders = 0
        let model = RenderQueueViewModel(
            persistenceURL: persistence,
            render: { _ in renders += 1; return files.output },
            save: { _ in }, postDelivery: { _, _ in }
        )
        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())
        #expect(model.isPersistenceBlocked)
        #expect(renders == 0)

        try FileManager.default.createDirectory(at: laterDirectory, withIntermediateDirectories: true)
        model.resume()

        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 1)
        #expect(model.isPersistenceBlocked == false)
        let persisted = try QueuePersister(storageURL: persistence).load()
        #expect(persisted.first?.status == .completed)
    }

    @Test func failedTransitionAfterPhotosSavePausesAndPreservesMedia() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var saves: [URL] = []
        var failOnceOutputConfirmed = true
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in files.output },
            save: { url in saves.append(url) },
            postDelivery: { _, _ in },
            persist: { jobs in
                if failOnceOutputConfirmed && jobs.contains(where: { $0.outputSavedToPhotos == true }) {
                    throw RecoveryTestError.write
                }
            }
        )

        model.enqueue(sourceURL: files.source, stockId: "test", iso: 400,
                      deliveryPreferences: RenderDeliveryPreferences())

        try await waitUntil { model.isPersistenceBlocked }
        // The confirmed Photos save must not be followed by further side effects.
        #expect(saves == [files.output])
        #expect(model.jobs.first?.status == .pending)
        #expect(FileManager.default.fileExists(atPath: files.output.path))
        #expect(FileManager.default.fileExists(atPath: files.source.path))

        // A working durable write resumes without re-saving the confirmed output.
        failOnceOutputConfirmed = false
        model.resume()
        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(saves == [files.output])
    }

    // MARK: - L04 awaiting-stock capture

    @Test func takeWithoutStockIsDurablyQueuedAwaitingStock() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var renders = 0
        var saves = 0
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { _ in saves += 1 },
            postDelivery: { _, _ in }, sessionId: launchSession
        )
        let id = try #require(model.enqueueAwaitingStock(sourceURL: files.source))
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.status == .awaitingStock)
        #expect(model.awaitingStockJobs.map(\.id) == [id])
        try await Task.sleep(for: .milliseconds(20))
        #expect(renders == 0)
        #expect(saves == 0)

        let relaunched = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { _ in saves += 1 },
            postDelivery: { _, _ in }, sessionId: launchSession
        )
        relaunched.onAppear()
        #expect(relaunched.jobs.count == 1)
        #expect(relaunched.jobs.first?.id == id)
        #expect(relaunched.jobs.first?.status == .awaitingStock)
        #expect(relaunched.awaitingStockJobs.count == 1)
    }

    @Test func assignStockResumesAwaitingEntryAndRenders() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([4, 5, 6]).write(to: files.output)
        var renders = 0
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { _ in }, postDelivery: { _, _ in }, sessionId: launchSession
        )
        let id = try #require(model.enqueueAwaitingStock(sourceURL: files.source))
        model.assignStock(jobId: id, stockId: "portra", iso: 200, gauge: .thirtyFiveMillimetre)

        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 1)
        #expect(model.jobs.first?.stockId == "portra")
        let persisted = try QueuePersister(storageURL: files.persistence).load().first
        #expect(persisted?.stockId == "portra")
        #expect(persisted?.status == .completed)
    }

    @Test func exportOriginalFromAwaitingEntrySavesWithoutRendering() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { url in saves.append(url) }, postDelivery: { _, _ in }, sessionId: launchSession
        )
        let id = try #require(model.enqueueAwaitingStock(sourceURL: files.source))
        model.exportOriginal(jobId: id)

        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 0)
        #expect(saves == [files.source])
        #expect(model.jobs.first?.sourceSavedToPhotos == true)
        #expect(FileManager.default.fileExists(atPath: files.source.path))
    }

    @Test func twoTakesWithoutStockBothSurviveRelaunch() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let second = files.directory.appendingPathComponent("second.mov")
        try Data([9, 9]).write(to: second)
        let model = RenderQueueViewModel(persistenceURL: files.persistence,
                                         render: { _ in files.output }, save: { _ in },
                                         postDelivery: { _, _ in }, sessionId: launchSession)
        let firstID = try #require(model.enqueueAwaitingStock(sourceURL: files.source))
        let secondID = try #require(model.enqueueAwaitingStock(sourceURL: second))
        #expect(model.awaitingStockJobs.count == 2)

        let relaunched = RenderQueueViewModel(persistenceURL: files.persistence,
                                              render: { _ in files.output }, save: { _ in },
                                              postDelivery: { _, _ in }, sessionId: launchSession)
        relaunched.onAppear()
        #expect(Set(relaunched.awaitingStockJobs.map(\.id)) == [firstID, secondID])
    }

    // MARK: - L05 validation-failed original

    @Test func validationFailedOriginalIsQueuedOriginalOnlyAndNeverRendered() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { url in saves.append(url) }, postDelivery: { _, _ in }, sessionId: launchSession
        )
        let accepted = model.enqueueOriginalOnly(sourceURL: files.source, reason: "1.30 s audio gap")
        #expect(accepted)
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.originalOnly == true)

        try await waitUntil { model.jobs.first?.status == .completed }
        #expect(renders == 0)
        #expect(saves == [files.source])
        let persisted = try QueuePersister(storageURL: files.persistence).load().first
        #expect(persisted?.originalOnly == true)
        #expect(persisted?.retainedReason == "1.30 s audio gap")
        #expect(persisted?.status == .completed)

        // A relaunch must not render an original-only entry.
        let relaunched = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in renders += 1; return files.output },
            save: { _ in }, postDelivery: { _, _ in }, sessionId: launchSession
        )
        relaunched.onAppear()
        try await Task.sleep(for: .milliseconds(20))
        #expect(renders == 0)
        #expect(relaunched.jobs.first?.status == .completed)
    }

    @Test func originalOnlySaveFailureSurvivesRestartAndRetries() async throws {
        let files = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var saves: [URL] = []
        var failSave = true
        let model = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in throw RecoveryTestError.render },
            save: { url in
                if failSave { throw RecoveryTestError.save }
                saves.append(url)
            },
            postDelivery: { _, _ in }, sessionId: launchSession
        )
        _ = model.enqueueOriginalOnly(sourceURL: files.source, reason: "1.30 s audio gap")
        try await waitUntil { model.jobs.first?.status == .failed }
        #expect(model.jobs.first?.sourceSavedToPhotos == false)
        #expect(model.jobs.first?.errorMessage?.contains("1.30 s audio gap") == true)

        failSave = false
        let relaunched = RenderQueueViewModel(
            persistenceURL: files.persistence,
            render: { _ in throw RecoveryTestError.render },
            save: { url in saves.append(url) },
            postDelivery: { _, _ in }, sessionId: launchSession
        )
        relaunched.onAppear()
        let id = try #require(relaunched.jobs.first?.id)
        #expect(relaunched.jobs.first?.status == .failed)
        relaunched.retry(jobId: id)
        try await waitUntil { relaunched.jobs.first?.status == .completed }
        #expect(saves == [files.source])
    }

    // MARK: - L05/L06 wiring contracts

    @Test func contentViewQueuesRetainedOriginalBeforeClearingHandoff() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("if renderQueueViewModel.enqueueOriginalOnly(sourceURL:"))
        #expect(screen.contains("clearRetainedOriginal()"))
        #expect(!screen.contains("saveOriginal(sourceURL:"))
        // The handoff may only be cleared inside the acceptance guard.
        #expect(!screen.contains("renderQueueViewModel.saveOriginal"))
    }

    @Test func productionRenderDoesNotDumpFramesAndKeepsPostDeliveryHook() throws {
        let model = try source("App/Modules/RenderQueue/RenderQueueViewModel.swift")
        #expect(!model.contains("dumpFrames"))
        #expect(!model.contains("\"frames/"))
        #expect(!model.contains("CGImageDestination"))
        #expect(model.contains("postDeliveryOperation"))
    }
}

private enum RecoveryTestError: Error, LocalizedError {
    case render, save, write
    var errorDescription: String? {
        switch self {
        case .render: "render broke"
        case .save: "Photos unavailable"
        case .write: "disk full"
        }
    }
}
