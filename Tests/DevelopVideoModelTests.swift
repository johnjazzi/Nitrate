import Foundation
import Testing

@MainActor
@Suite("Develop video model")
struct DevelopVideoModelTests {
    private enum Failure: Error { case denied }

    private struct Files {
        let directory: URL
        let output: URL
        let persistence: URL
    }

    // MARK: - Fixtures

    private static func scratch() throws -> Files {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("render_out.mov")
        try Data([9, 9, 9]).write(to: output)
        return Files(directory: directory, output: output,
                     persistence: directory.appendingPathComponent("queue.json"))
    }

    private static func clipFile(_ files: Files) throws -> URL {
        let url = files.directory.appendingPathComponent("clip_import_\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private static func transfer(_ url: URL, directory: URL) -> DevelopClipTransfer {
        DevelopClipTransfer(lease: VideoImportFileLease(url: url, directory: directory),
                            originalFilename: url.lastPathComponent)
    }

    private static func inspected(_ url: URL) -> ImportedVideo {
        ImportedVideo(url: url, originalFilename: url.lastPathComponent, durationSeconds: 1.5,
                      pixelWidth: 1920, pixelHeight: 1080, nominalFrameRate: 30)
    }

    private static func stock() -> FilmStockConfig {
        FilmStockConfig(stockId: "test", displayName: "Test", category: .video, lutName: "test.cube",
                        halationStrength: 0.2, glowStrength: 0.1, grainSize: 1, defaultISO: 400)
    }

    private static func queue(_ files: Files,
                              render: @escaping RenderQueueViewModel.RenderOperation,
                              persist: (([RenderJob]) throws -> Void)? = nil) -> RenderQueueViewModel {
        RenderQueueViewModel(persistenceURL: files.persistence, render: render, save: { _ in }, persist: persist)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool,
                                  _ message: String = "Timed out waiting for state") async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(message)")
    }

    // MARK: - Selection lifecycle

    @Test func selectingAClipTransfersAndInspectsThenExposesIt() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(source, directory: files.directory) })

        try await Self.waitUntil { model.video != nil }
        #expect(model.video?.url == source)
        #expect(model.isLoading == false)
        #expect(model.errorMessage == nil)
    }

    @Test func deferredTransferKeepsLoadingUntilItCompletes() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })
        let gate = DevelopGate()

        model.select(transfer: { await gate.suspend(); return Self.transfer(source, directory: files.directory) })

        #expect(model.isLoading)
        #expect(model.video == nil)
        await gate.resume()
        try await Self.waitUntil { model.video != nil }
        #expect(model.isLoading == false)
    }

    @Test func newSelectionFencesLateResultAndDiscardsItsOwnedFile() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = try Self.clipFile(files)
        let second = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })
        let gate = DevelopGate()

        model.select(transfer: { await gate.suspend(); return Self.transfer(first, directory: files.directory) })
        await gate.waitUntilSuspended()
        model.select(transfer: { Self.transfer(second, directory: files.directory) })
        try await Self.waitUntil { model.video?.url == second }

        await gate.resume()
        // The late first result is fenced and its unqueued file released.
        try await Self.waitUntil { !FileManager.default.fileExists(atPath: first.path) }
        #expect(model.video?.url == second)
    }

    @Test func cancellingSelectionDiscardsUnqueuedClip() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })
        let gate = DevelopGate()

        model.select(transfer: { await gate.suspend(); return Self.transfer(source, directory: files.directory) })
        await gate.waitUntilSuspended()
        model.cancelSelection()

        #expect(model.isLoading == false)
        #expect(model.video == nil)
        await gate.resume()
        try await Self.waitUntil { !FileManager.default.fileExists(atPath: source.path) }
        #expect(model.video == nil)
    }

    @Test func canRenderRequiresClipStockAndNoActiveRender() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        #expect(model.canRender(stock: Self.stock(), queue: queue) == false)
        model.select(transfer: { Self.transfer(source, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }
        #expect(model.canRender(stock: nil, queue: queue) == false)
        #expect(model.canRender(stock: Self.stock(), queue: queue))
    }

    // MARK: - Render acceptance

    @Test func renderEnqueuesAcceptedJobAndTransfersOwnership() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        let gate = DevelopGate()
        let queue = Self.queue(files, render: { _ in await gate.suspend(); return files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(source, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }

        let id = try #require(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue))
        #expect(model.activeJobID == id)
        #expect(model.video == nil)
        #expect(queue.jobs.contains { $0.id == id && $0.isImportedVideo == true })
        // Ownership moved to the queue: the file is no longer an unqueued discard.
        #expect(FileManager.default.fileExists(atPath: source.path))
        await gate.resume()
    }

    @Test func failedEnqueueRetainsSelectionForRetry() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let source = try Self.clipFile(files)
        var deny = true
        let queue = Self.queue(files, render: { _ in files.output }, persist: { _ in
            if deny { throw Failure.denied }
        })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(source, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }

        #expect(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue) == nil)
        #expect(queue.isPersistenceBlocked)
        #expect(model.video != nil)
        #expect(model.errorMessage != nil)

        deny = false
        queue.resume()
        let retried = try #require(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue))
        #expect(queue.jobs.contains { $0.id == retried && $0.isImportedVideo == true })
    }

    @Test func renderRefusesDuplicateWhileAJobIsActive() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = try Self.clipFile(files)
        let second = try Self.clipFile(files)
        let gate = DevelopGate()
        let queue = Self.queue(files, render: { _ in await gate.suspend(); return files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(first, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }
        let id = try #require(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue))

        // A new clip selected while the render is active keeps the job reference.
        model.select(transfer: { Self.transfer(second, directory: files.directory) })
        try await Self.waitUntil { model.video?.url == second }
        #expect(model.activeJobID == id)

        #expect(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue) == nil)
        #expect(queue.jobs.filter { $0.isImportedVideo == true }.count == 1)
        await gate.resume()
    }

    @Test func newSelectionClearsOnlyASettledJobReference() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = try Self.clipFile(files)
        let second = try Self.clipFile(files)
        let queue = Self.queue(files, render: { _ in files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(first, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }
        let id = try #require(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue))
        try await Self.waitUntil { queue.jobs.first { $0.id == id }?.status == .completed }
        #expect(model.activeJobID == id)

        model.select(transfer: { Self.transfer(second, directory: files.directory) })
        #expect(model.activeJobID == nil)
    }

    @Test func leavingDevelopKeepsAcceptedJobAndDropsUnqueuedSelection() async throws {
        let files = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = try Self.clipFile(files)
        let queued = try Self.clipFile(files)
        let renderGate = DevelopGate()
        let queue = Self.queue(files, render: { _ in await renderGate.suspend(); return files.output })
        let model = DevelopVideoModel(queue: queue, inspect: { url, _ in Self.inspected(url) })

        model.select(transfer: { Self.transfer(first, directory: files.directory) })
        try await Self.waitUntil { model.video != nil }
        let id = try #require(model.render(stock: Self.stock(), iso: 400, gauge: .neutral, queue: queue))

        // A new, unqueued selection in flight when Develop is left.
        let transferGate = DevelopGate()
        model.select(transfer: { await transferGate.suspend(); return Self.transfer(queued, directory: files.directory) })
        await transferGate.waitUntilSuspended()
        model.leaveDevelop()

        #expect(model.activeJobID == id)
        #expect(model.video == nil)
        #expect(model.isLoading == false)
        #expect(queue.jobs.first { $0.id == id }?.status != .failed)

        await transferGate.resume()
        try await Self.waitUntil { !FileManager.default.fileExists(atPath: queued.path) }
        #expect(model.activeJobID == id)
        #expect(queue.jobs.contains { $0.id == id })
        await renderGate.resume()
    }
}

/// Suspends a lifecycle step until the test resumes it.
private actor DevelopGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func suspend() async {
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilSuspended() async {
        for _ in 0..<400 {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The deferred provider was not entered.")
    }
    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
