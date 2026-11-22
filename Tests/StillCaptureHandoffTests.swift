import Foundation
import Testing

/// A captured still must survive both windows where it could be lost: the
/// process dying between the DNG write and any queue entry, and the queue's own
/// persistence failing during the handoff.
///
/// The marker names the media kind before the file exists, records whether the
/// file validated, and is cleared only by durable queue acceptance. Recovery
/// must produce exactly one accessible photo, never an unfinished one.
@Suite("Still capture handoff", .serialized)
@MainActor
struct StillCaptureHandoffTests {
    private let launchSession = "this-launch"

    private struct Files {
        let directory: URL
        let queue: URL
        let captured: URL
    }

    /// A capture folder shaped like the camera's own: one folder per still, each
    /// holding a `capture.dng`.
    private func scratch(stills: Int = 1) throws -> (Files, [URL]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var captures: [URL] = []
        for index in 0..<stills {
            let folder = directory.appendingPathComponent("Photos/\(index)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dng = folder.appendingPathComponent("capture.dng")
            try Data([1, 2, 3, 4]).write(to: dng)
            captures.append(dng)
        }
        let files = Files(directory: directory,
                          queue: directory.appendingPathComponent("queue.json"),
                          captured: captures[0])
        return (files, captures)
    }

    private func journal(_ files: Files) -> CaptureJournal {
        CaptureJournal(root: files.directory.appendingPathComponent("journal"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for queue state")
    }

    // MARK: - Validated DNG with a missing or late terminal callback

    @Test func validatedStillSurvivesTimeoutAndRejectsLateCallbacks() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var transaction = PhotoCaptureTransactionState(uniqueID: 42)
        let processed = transaction.acceptCallback(uniqueID: 42)
        let timeout = transaction.timeout()
        #expect(processed == .accepted)
        #expect(timeout == .markedFailed)
        let handoff = PhotoCaptureHandoffPolicy.handoff(validated: files.captured,
                                                       failure: nil, timedOut: transaction.timedOut)
        #expect(handoff.url == files.captured)
        #expect(handoff.failure == nil)
        let firstFinish = transaction.finish(uniqueID: 42)
        let lateFinish = transaction.finish(uniqueID: 42)
        let lateProcessing = transaction.acceptCallback(uniqueID: 42)
        #expect(firstFinish)
        #expect(!lateFinish, "The late terminal cannot enqueue twice.")
        #expect(lateProcessing == .terminal)
    }

    @Test func timeoutNeverMakesAnIncompleteOrFailedStillDeliverable() {
        let incomplete = PhotoCaptureHandoffPolicy.handoff(validated: nil, failure: nil, timedOut: true)
        #expect(incomplete.url == nil)
        #expect(incomplete.failure != nil)
        let failed = PhotoCaptureHandoffPolicy.handoff(validated: URL(fileURLWithPath: "/invalid.dng"),
                                                      failure: "DNG validation failed", timedOut: true)
        #expect(failed.url == nil)
        #expect(failed.failure == "DNG validation failed")
    }

    /// The policy alone cannot catch a caller poisoning its failure argument.
    /// The native framework callback still needs separate device qualification.
    @Test func timeoutCallerDoesNotHideTheValidatedURLBeforeHandoff() throws {
        let source = try String(contentsOf: TestRepository.url(
            for: "App/Modules/CameraCapture/CameraPhotoCapture.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "case .markedFailed:"))
        let end = try #require(source.range(of: "case .alreadyFailed, .terminal: break",
                                           range: start.upperBound..<source.endIndex))
        let timeout = String(source[start.upperBound..<end.lowerBound])
        #expect(!timeout.contains("self.failure ="),
                "Only the handoff policy may turn this timeout into a failure.")
        #expect(timeout.contains("self.finishAfterTimeout()"))
        #expect(source.contains("PhotoCaptureHandoffPolicy.handoff(validated: dngURL, failure: failure, timedOut: true)"))
    }

    // MARK: - Queue write failure during the handoff

    @Test func repeatedReconciliationKeepsAnUnpersistedRescueMarker() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        journal.markPending(files.captured, mediaKind: .photo)
        journal.markValidated(files.captured, mediaKind: .photo)
        var canWrite = false
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            persist: { jobs in
                guard canWrite else { throw StillHandoffTestError.write }
                try QueuePersister(storageURL: files.queue).save(jobs)
            }, journal: journal, sessionId: launchSession)
        model.onAppear()
        #expect(model.isPersistenceBlocked)
        #expect(model.jobs.count == 1)
        #expect(journal.pendingHandoffs().count == 1)
        model.reconcileOrphanedCaptures()
        #expect(journal.pendingHandoffs().count == 1,
                "An in-memory rescue is not durable queue acceptance.")
        #expect(saves.isEmpty)
        canWrite = true
        model.resume()
        try await waitUntil { model.jobs.first?.status == .completed }
        model.reconcileOrphanedCaptures()
        #expect(journal.pendingHandoffs().isEmpty)
        #expect(try QueuePersister(storageURL: files.queue).load().count == 1)
        #expect(saves == [files.captured])
    }

    @Test func queueWriteFailureKeepsTheMarkerAndRecoversOnePhoto() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        journal.markPending(files.captured, mediaKind: .photo)
        journal.markValidated(files.captured, mediaKind: .photo)

        var canWrite = false
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            persist: { _ in if !canWrite { throw StillHandoffTestError.write } },
            journal: journal, sessionId: launchSession)

        let jobID = model.enqueuePhoto(sourceURL: files.captured, stockId: "portra", iso: 400,
                                       gauge: .neutral, cropZoom: 1, seed: 0)
        #expect(jobID == nil, "A failed durable write must not report acceptance.")
        #expect(model.isPersistenceBlocked)
        #expect(journal.pendingHandoffs().count == 1,
                "Recovery state is cleared only after durable queue acceptance.")
        #expect(journal.pendingHandoffs().first?.validated == true)

        // Relaunch: the still is recovered as exactly one photo job, delivered by
        // the photo saver, and the marker is retired.
        canWrite = true
        let relaunched = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: journal, sessionId: launchSession)
        relaunched.onAppear()
        try await waitUntil { relaunched.jobs.first?.status == .completed }

        #expect(relaunched.jobs.count == 1)
        #expect(relaunched.jobs.first?.isPhoto == true)
        #expect(relaunched.jobs.first?.originalOnly == true)
        #expect(saves == [files.captured])
        #expect(journal.pendingHandoffs().isEmpty)

        // Reconciling again must not manufacture a second copy of the photo.
        relaunched.reconcileOrphanedCaptures()
        try await Task.sleep(for: .milliseconds(30))
        #expect(relaunched.jobs.count == 1)
        #expect(saves == [files.captured])
    }

    // MARK: - Termination before enqueue

    @Test func validStillLeftByATerminationIsRecoveredOnce() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        // Exactly the state the camera leaves: DNG validated, no queue entry.
        journal.markPending(files.captured, mediaKind: .photo)
        journal.markValidated(files.captured, mediaKind: .photo)
        #expect(!FileManager.default.fileExists(atPath: files.queue.path))

        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: journal, sessionId: launchSession)
        model.onAppear()
        try await waitUntil { model.jobs.first?.status == .completed }

        #expect(model.jobs.count == 1)
        #expect(saves == [files.captured])
        #expect(model.jobs.first?.isPhoto == true)
        #expect(journal.pendingHandoffs().isEmpty)
    }

    // MARK: - Incomplete DNG

    @Test func incompleteStillIsNeverExported() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        // Marked before the write, never validated: an unfinished fragment.
        journal.markPending(files.captured, mediaKind: .photo)

        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in renders += 1; throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: journal, sessionId: launchSession)
        model.onAppear()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.jobs.isEmpty, "An incomplete DNG must not become a job.")
        #expect(saves.isEmpty, "An incomplete DNG must not be exported.")
        #expect(renders == 0)
        #expect(journal.pendingHandoffs().isEmpty, "The marker is retired, not retried forever.")
        #expect(model.externalErrorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: files.captured.path),
                "Nothing here deletes a capture the app did not finish writing.")
    }

    // MARK: - More than one handoff in flight

    @Test func twoInFlightStillsKeepTheirOwnMarkers() throws {
        let (files, captures) = try scratch(stills: 2)
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        // Both stills are named `capture.dng`; only their folders differ.
        journal.markPending(captures[0], mediaKind: .photo)
        journal.markValidated(captures[0], mediaKind: .photo)
        journal.markPending(captures[1], mediaKind: .photo)

        let pending = journal.pendingHandoffs()
        #expect(pending.count == 2, "A single overwriteable marker would lose one handoff.")
        #expect(Set(pending.map(\.url)) == Set(captures))
        #expect(pending.first { $0.url == captures[0] }?.validated == true)
        #expect(pending.first { $0.url == captures[1] }?.validated == false)

        journal.acknowledge(captures[0])
        #expect(journal.pendingHandoffs().map(\.url) == [captures[1]])
    }

    // MARK: - Journal compatibility

    @Test func legacyVideoMarkerStillDecodesAndIsAcknowledged() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        let legacyRoot = files.directory.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        // An entry written by the version that had neither field.
        let legacy = ["source": files.captured.path, "createdAt": 1_000.0] as [String: Any]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: legacyRoot.appendingPathComponent("capture.json"))

        let pending = journal.pendingHandoffs()
        #expect(pending.count == 1)
        #expect(pending.first?.mediaKind == .video)
        #expect(pending.first?.validated == false)

        // Acknowledging an upgraded entry also retires its legacy-named marker.
        journal.acknowledge(files.captured)
        #expect(journal.pendingHandoffs().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: legacyRoot.path).isEmpty)
    }
}

private enum StillHandoffTestError: Error, LocalizedError {
    case render, write
    var errorDescription: String? {
        switch self {
        case .render: "render broke"
        case .write: "disk full"
        }
    }
}
