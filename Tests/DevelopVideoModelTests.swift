import Foundation
import CoreGraphics
import ImageIO
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


/// The photo half of Develop: the same select → validate → accept lifecycle as a
/// clip, and a stable grain seed per file so re-developing reproduces the grain.
struct DevelopPhotoSelectionTests {
    private static func photo(_ url: URL) -> ImportedPhoto {
        ImportedPhoto(url: url, originalFilename: url.lastPathComponent,
                      pixelWidth: 4032, pixelHeight: 3024, iso: 800, capturedAt: nil)
    }

    /// Poll until the main-actor model reports the transition. The predicate runs
    /// on the main actor so it can read the observed model directly.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A re-developed file must leave Develop's button ENABLED and must actually
    /// render again — the adopted file has no lease (the queue owns it), and the
    /// job already exists, so both the enable check and the enqueue used to
    /// silently do nothing.
    @MainActor @Test func readoptingAPhotoEnablesDevelopAndRendersAgain() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("readopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo_import_A.dng")
        try Data([1]).write(to: source)

        let queue = RenderQueueViewModel(persistenceURL: folder.appendingPathComponent("q.json"),
            render: { _ in
                let out = folder.appendingPathComponent("out-\(UUID().uuidString).jpg")
                try Data([2]).write(to: out)
                return out
            }, save: { _ in })
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { url, _ in Self.photo(url) })
        let stock = FilmStockConfig(stockId: "kodak5207", displayName: "5207", category: .video,
                                    lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 250)

        // Develop it once, through the model, so the panel holds the job.
        await model.adoptExistingPhoto(url: source, originalFilename: "A.dng")
        let first = try #require(model.render(stock: stock, iso: 250, gauge: .neutral, queue: queue))
        for _ in 0..<400 where queue.jobs.first?.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.jobs.first?.status == .completed)
        #expect(model.activeJobID == first, "a finished develop is still referenced")

        // Re-develop: back to step one with the same file. The finished job must
        // stop being referenced, or the panel keeps showing its completed state
        // and the gauge controls never appear.
        await model.adoptExistingPhoto(url: source, originalFilename: "A.dng")
        #expect(model.activeJobID == nil,
                "adopting clears the settled job so the panel shows step one")
        #expect(model.photo?.url == source)
        #expect(model.canRender(stock: stock, queue: queue),
                "an adopted file has no lease; the button must still be enabled")

        // Pressing Develop renders again instead of returning the finished job.
        let id = try #require(model.render(stock: stock, iso: 250, gauge: .eightMillimetre, queue: queue))
        #expect(id == first, "the same job is re-rendered, not duplicated")
        for _ in 0..<400 where queue.jobs.first?.printGauge != .eightMillimetre {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.jobs.first?.printGauge == .eightMillimetre,
                "the re-develop applies the settings chosen on the second visit")
    }

    /// A re-develop whose original is gone must SAY so. `redevelopPhotos` skips
    /// such a job (a bulk action must not fail on one cleaned-up file), and the
    /// model used to report the skipped id as a success — the panel went back to
    /// the old delivered still and nothing new was ever saved.
    @MainActor @Test func aRedevelopWithoutItsOriginalIsNotReportedAsSuccess() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo_import_GONE.dng")
        try Data([1]).write(to: source)

        let queue = RenderQueueViewModel(persistenceURL: folder.appendingPathComponent("q.json"),
            render: { _ in
                let out = folder.appendingPathComponent("out-\(UUID().uuidString).jpg")
                try Data([2]).write(to: out)
                return out
            }, save: { _ in })
        // The photo's own file is stubbed, so adopting still works after the
        // original is deleted — which is the state this bug is about.
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { url, _ in Self.photo(url) })
        let stock = FilmStockConfig(stockId: "kodak5207", displayName: "5207", category: .video,
                                    lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 250)

        await model.adoptExistingPhoto(url: source, originalFilename: "GONE.dng")
        let first = try #require(model.render(stock: stock, iso: 250, gauge: .neutral, queue: queue))
        for _ in 0..<400 where queue.jobs.first?.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.jobs.first?.status == .completed)

        // The owned original is cleaned up (cache purge, storage pressure).
        try FileManager.default.removeItem(at: source)
        await model.adoptExistingPhoto(url: source, originalFilename: "GONE.dng")
        let again = model.render(stock: stock, iso: 250, gauge: .eightMillimetre, queue: queue)

        #expect(again == nil, "a skipped re-develop must not return a job id")
        #expect(model.errorMessage?.contains("no longer on the device") == true,
                "the reason must be said, not swallowed: \(model.errorMessage ?? "nil")")
        #expect(queue.jobs.first?.printGauge == .neutral, "the old develop is untouched")
        #expect(queue.jobs.first?.id == first)
    }

    /// The pill's choice must survive to the render. It once did not: the value
    /// sat in a stored property defaulting to neutral, and an import chosen at
    /// -2 stops developed at 0.
    @Test func theChosenPullReachesTheDevelop() {
        let pulled = DevelopVideoModel.resolvedPushPull(automatic: false, stops: .pullTwo)
        #expect(pulled.stops == .pullTwo)
        #expect(pulled.origin == .manual)
        #expect(pulled == .manual(.pullTwo), "a manual choice must not be neutral")

        // An import has no meter, so automatic cannot invent a pull.
        let automatic = DevelopVideoModel.resolvedPushPull(automatic: true, stops: .none)
        #expect(automatic.stops == .none)
    }

    /// A pick where EVERY file is refused must say why. The reasons used to live
    /// only in the staging view, which never appears when nothing staged — three
    /// NEFs spun, stopped, and explained nothing.
    @MainActor @Test func aFullyRefusedPickReportsTheReason() async throws {
        let queue = RenderQueueViewModel()
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { _, _ in
            throw PhotoImportError.unsupported(found: "JPEG")
        })
        func transfer() -> DevelopVideoModel.PhotoTransferOperation {
            {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("refused_\(UUID().uuidString).nef")
                try Data([1]).write(to: url)
                return DevelopVideoModel.DevelopPhotoTransfer(
                    lease: VideoImportFileLease(url: url), originalFilename: "DSC_4800.NEF")
            }
        }

        await model.stagePhotos(transfers: [transfer(), transfer(), transfer()])

        #expect(model.bulk.isEmpty, "nothing staged")
        #expect(queue.jobs.isEmpty, "nothing queued")
        let message = try #require(model.errorMessage)
        #expect(message.contains("3 files could not be added"), "the count must show: \(message)")
        #expect(message.contains("Not a raw photo"), "the reason must show: \(message)")
        #expect(message.contains("JPEG"), "what it found must show: \(message)")
    }

    /// The refusal must not wait for a decode: a picked JPEG or HEIC is named in
    /// its first bytes, and a raw container is a TIFF.
    @Test func renderedImagesAreRecognisedWithoutADecoder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sniff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(bytes + [UInt8](repeating: 0, count: 32)).write(to: url)
            return url
        }

        // Rendered images: refused on the sniff alone.
        let jpeg = try file("a.NEF", [0xFF, 0xD8, 0xFF, 0xE0])
        let png = try file("b.DNG", [0x89, 0x50, 0x4E, 0x47])
        var heicBytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        heicBytes += Array("ftypheic".utf8)
        let heic = try file("c.DNG", heicBytes)

        for url in [jpeg, png, heic] {
            #expect(RawPhotoType.isDefinitelyRenderedImage(url) == true)
            #expect(!RawPhotoType.isRaw(url), "\(url.lastPathComponent) is not a raw")
        }

        // A TIFF container is where every raw this app develops lives.
        let tiff = try file("d.NEF", [0x49, 0x49, 0x2A, 0x00])
        #expect(RawPhotoType.isDefinitelyRenderedImage(tiff) == false)
        #expect(RawPhotoType.isRaw(tiff), "a TIFF container is not refused by the sniff")

        // Unclassifiable bytes fall through to the name.
        let opaque = try file("e.DNG", [0x00, 0x00, 0x00, 0x00])
        #expect(RawPhotoType.isDefinitelyRenderedImage(opaque) == nil)
        #expect(RawPhotoType.isRaw(opaque))
    }

    /// A bulk pick queues what it can and reports what it could not, so one bad
    /// file never abandons the rest of the selection.
    @MainActor @Test func bulkPickQueuesTheGoodFilesAndSkipsTheRest() async throws {
        let queue = RenderQueueViewModel()
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { url, name in
            // Refuse anything whose name says it is not a raw.
            guard name.lowercased().hasSuffix(".dng") || name.lowercased().hasSuffix(".nef") else {
                throw PhotoImportError.unsupported(found: "JPEG")
            }
            return Self.photo(url)
        })
        let stock = FilmStockConfig(stockId: "kodak5207", displayName: "5207", category: .video,
                                    lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 250)

        func transfer(_ name: String) -> DevelopVideoModel.PhotoTransferOperation {
            {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bulk_\(UUID().uuidString)_\(name)")
                try Data(repeating: 1, count: 16).write(to: url)
                return DevelopVideoModel.DevelopPhotoTransfer(
                    lease: VideoImportFileLease(url: url), originalFilename: name)
            }
        }

        // Staging holds them; nothing is queued until the settings are chosen.
        await model.stagePhotos(transfers: [transfer("A.dng"), transfer("B.JPG"), transfer("C.nef")])
        #expect(model.bulk.count == 2, "the two developable raws are staged")
        #expect(model.bulk.skipped.count == 1, "the JPEG is reported, not staged")
        #expect(queue.jobs.isEmpty, "staging must not render anything")

        let result = model.commitBulk(stock: stock, gauge: .neutral, pushPull: nil, queue: queue)
        #expect(result.queued == 2, "two developable raws go to the queue")
        #expect(queue.jobs.count == 2)
        #expect(queue.jobs.allSatisfy { $0.isImportedPhoto == true })
        #expect(model.bulk.isEmpty, "the staging area is cleared once handed over")
    }

    /// A develop delivers the develop and nothing else.
    ///
    /// The raw came from the library, so "save the original" would either
    /// duplicate something already there or — for a maker's raw Photos will not
    /// store — fail a render that succeeded. The job carries the flag, so this
    /// does not depend on the delivery switch the camera uses.
    @MainActor @Test func developingAnImportedRawNeverQueuesAnOriginalSave() async throws {
        let queue = RenderQueueViewModel()
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { url, _ in Self.photo(url) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo_import_\(UUID().uuidString).nef")
        try Data(repeating: 1, count: 32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectPhoto { DevelopVideoModel.DevelopPhotoTransfer(
            lease: VideoImportFileLease(url: url), originalFilename: "DSC_4800.NEF") }
        await Self.waitUntil { !model.isLoading }
        let stock = FilmStockConfig(stockId: "kodak5207", displayName: "5207", category: .video,
                                    lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 250)
        let id = try #require(model.render(stock: stock, iso: 400, gauge: .neutral, queue: queue))
        let job = try #require(queue.jobs.first { $0.id == id })
        #expect(job.isPhoto == true)
        #expect(job.isImportedPhoto == true)
        #expect(job.shouldSaveOriginal == false,
                "an imported raw has no original to deliver")
    }

    @MainActor @Test func selectingAPhotoAcceptsItAndClearsAnyClip() async throws {
        let queue = RenderQueueViewModel()
        var inspected: URL?
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { url, _ in
            inspected = url
            return Self.photo(url)
        })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo_import_\(UUID().uuidString).dng")
        try Data(repeating: 1, count: 32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectPhoto { DevelopVideoModel.DevelopPhotoTransfer(
            lease: VideoImportFileLease(url: url), originalFilename: "IMG_0001.DNG") }
        await Self.waitUntil { !model.isLoading }

        #expect(model.photo?.url == url)
        #expect(inspected == url)
        #expect(model.video == nil)
        #expect(model.errorMessage == nil)
    }

    /// A picked image that is not raw is refused, and the refusal names what it
    /// found rather than only saying no.
    @MainActor @Test func aNonRawPhotoIsRefusedWithItsReason() async {
        let queue = RenderQueueViewModel()
        let model = DevelopVideoModel(queue: queue, inspectPhoto: { _, _ in
            throw PhotoImportError.unsupported(found: "JPEG")
        })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo_import_\(UUID().uuidString).dng")

        model.selectPhoto { DevelopVideoModel.DevelopPhotoTransfer(
            lease: VideoImportFileLease(url: url), originalFilename: "IMG_0001.JPG") }
        await Self.waitUntil { !model.isLoading }

        #expect(model.photo == nil)
        let message = model.errorMessage ?? ""
        // One clause on screen: what it is, and that it is not developable. The
        // supported formats moved into the About panel behind "Why?".
        #expect(message.contains("Not a raw photo"), "the refusal must name the problem: \(message)")
        #expect(message.contains("JPEG"), "the refusal must name what it found: \(message)")
        #expect(!message.contains("DNG"), "the format list belongs in the help sheet: \(message)")
    }

    /// The gate answers "can the system's RAW pipeline develop this", not "is
    /// the extension familiar": a JPEG carrying a raw name is refused, which a
    /// name or UTI list alone would have waved through.
    @Test func rawNamesDoNotCarryAJPEGPastTheGate() async throws {
        let nefNamed = Self.jpeg(at: "IMG_0001.NEF")
        let dngNamed = Self.jpeg(at: "IMG_0002.dng")
        defer {
            try? FileManager.default.removeItem(at: nefNamed)
            try? FileManager.default.removeItem(at: dngNamed)
        }
        #expect(!PhotoImportService.canDevelop(nefNamed), "a JPEG named .NEF must be refused")
        #expect(!PhotoImportService.canDevelop(dngNamed), "a JPEG named .dng must be refused")
        #expect(PhotoImportService.canDevelop(URL(fileURLWithPath: "/nonexistent.dng")) == false)

        // And the picker's gate throws the named refusal rather than copying it.
        await #expect(throws: PhotoImportError.self) {
            try await PhotoImportService.validateRaw(at: nefNamed)
        }
    }

    /// A 1x1 JPEG on disk, under whatever name the test needs.
    private static func jpeg(at name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    @Test func developedPhotoGrainSeedIsStablePerFile() {
        let first = URL(fileURLWithPath: "/tmp/photo_import_A.dng")
        let same = URL(fileURLWithPath: "/tmp/photo_import_A.dng")
        let other = URL(fileURLWithPath: "/tmp/photo_import_B.dng")
        #expect(DevelopVideoModel.grainSeed(for: Self.photo(first))
                == DevelopVideoModel.grainSeed(for: Self.photo(same)))
        #expect(DevelopVideoModel.grainSeed(for: Self.photo(first))
                != DevelopVideoModel.grainSeed(for: Self.photo(other)))
    }

    @Test func rawPhotoIdentityNamesTheFileFactsNotTheWorkingName() throws {
        let url = URL(fileURLWithPath: "/tmp/photo_import_\(UUID().uuidString).dng")
        let inspected = Self.photo(url)
        #expect(inspected.detailSummary.contains("4032 × 3024"))
        #expect(inspected.detailSummary.contains("ISO 800"))
        #expect(!inspected.detailSummary.contains("photo_import_"),
                "the working file name must never reach the panel")
    }
}
