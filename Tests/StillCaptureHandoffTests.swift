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

    private func journal(_ files: Files, session: UUID = CaptureJournal.processSession) -> CaptureJournal {
        CaptureJournal(root: files.directory.appendingPathComponent("journal"), sessionID: session)
    }

    /// A 256×256 Bayer DNG that ImageIO really decodes as RAW. The promotion
    /// gate refuses placeholder bytes on purpose, so the acceptance test needs
    /// a genuine container.
    private func writeDecodableDNG(_ url: URL) throws {
        try MinimalDNG.data(width: 256, height: 256).write(to: url)
    }

    /// The camera's post-validation record, shaped exactly like
    /// `CameraPhotoCapture.writeManifest`. `overrides` lets each refusal case
    /// corrupt one fact while the rest of the record still looks complete.
    @discardableResult
    private func writeManifest(for dng: URL, status: String = "complete",
                               removing: Set<String> = [],
                               overrides: [String: Any] = [:]) throws -> [String: Any] {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dng.path)[.size] as? NSNumber)?.intValue ?? 0
        var manifest: [String: Any] = [
            "status": status,
            "dng": "capture.dng",
            "dngReadable": "true",
            "dngBytes": String(bytes),
            "transactionID": "42",
            "rawWidth": "256", "rawHeight": "256",
            "resolvedRawWidth": "256", "resolvedRawHeight": "256",
            "actualFileType": "com.adobe.raw-image",
            "actualRawPixelFormat": String(0x62676772),
        ]
        for key in removing { manifest.removeValue(forKey: key) }
        manifest.merge(overrides) { _, replacement in replacement }
        let url = dng.deletingLastPathComponent().appendingPathComponent("capture.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return manifest
    }

    private func markerFiles(_ files: Files) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath:
            files.directory.appendingPathComponent("journal").path)
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
        try journal.markPending(files.captured, mediaKind: .photo)
        try journal.markValidated(files.captured, mediaKind: .photo)
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
        try journal.markPending(files.captured, mediaKind: .photo)
        try journal.markValidated(files.captured, mediaKind: .photo)

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
        try journal.markPending(files.captured, mediaKind: .photo)
        try journal.markValidated(files.captured, mediaKind: .photo)
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
        let writer = journal(files, session: UUID())
        // Marked before the write, never validated: an unfinished fragment.
        try writer.markPending(files.captured, mediaKind: .photo)
        let recovery = journal(files, session: UUID())

        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in renders += 1; throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: recovery, sessionId: launchSession)
        model.onAppear()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.jobs.isEmpty, "An incomplete DNG must not become a job.")
        #expect(saves.isEmpty, "An incomplete DNG must not be exported.")
        #expect(renders == 0)
        #expect(writer.pendingHandoffs().count == 1, "Quarantine keeps the only durable reference.")
        #expect(model.captureRecoveryIssues.map(\.url) == [files.captured])
        model.reconcileOrphanedCaptures()
        #expect(model.captureRecoveryIssues.count == 1)
        #expect(writer.pendingHandoffs().count == 1)
        #expect(FileManager.default.fileExists(atPath: files.captured.path),
                "Nothing here deletes a capture the app did not finish writing.")
    }

    @Test func uncheckedWrittenStillStaysVisibleAcrossRelaunchAndRetry() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let writer = journal(files, session: UUID())
        let bytes = try Data(contentsOf: files.captured)
        try writer.markPending(files.captured, mediaKind: .photo)
        // Same durable state for death after atomic write/before validation, or
        // after validation/before a failed validated-marker replacement.
        for _ in 0..<2 {
            var saves = 0
            let relaunched = RenderQueueViewModel(persistenceURL: files.queue,
                render: { _ in throw StillHandoffTestError.render }, save: { _ in saves += 1 },
                journal: journal(files, session: UUID()), sessionId: launchSession)
            relaunched.onAppear()
            relaunched.reconcileOrphanedCaptures()
            #expect(relaunched.jobs.isEmpty)
            #expect(saves == 0)
            #expect(relaunched.captureRecoveryIssues.map(\.url) == [files.captured])
            #expect(relaunched.captureRecoveryIssues.allSatisfy { !$0.retryable },
                    "No retry can validate a file whose validation record is gone.")
            #expect(writer.pendingHandoffs().count == 1)
            #expect(try Data(contentsOf: files.captured) == bytes)
        }
    }

    @Test func failedValidatedMarkerStillAllowsDurableLiveHandoff() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let directory = files.directory.appendingPathComponent("journal")
        let journal = journal(files)
        try journal.markPending(files.captured, mediaKind: .photo)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        var refused = false
        do { try journal.markValidated(files.captured, mediaKind: .photo) }
        catch { refused = true }
        #expect(refused)
        #expect(journal.pendingHandoffs().first?.validated == false)
        let bytes = try Data(contentsOf: files.captured)
        let model = RenderQueueViewModel(persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render }, save: { _ in },
            journal: journal, sessionId: launchSession)
        model.renderAllowed = { false }
        // Simulates the live callback's already validated URL, not RAW validation.
        let accepted = model.enqueuePhoto(sourceURL: files.captured, stockId: "portra", iso: 400,
                                          gauge: .neutral, cropZoom: 1, seed: 0)
        #expect(accepted != nil)
        #expect(try QueuePersister(storageURL: files.queue).load().count == 1)
        // Acknowledgement can also fail while storage is denied. A durable
        // existing job, not an additional rescue, wins after relaunch/retry.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let relaunched = RenderQueueViewModel(persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render }, save: { _ in },
            journal: journal, sessionId: launchSession)
        relaunched.renderAllowed = { false }
        relaunched.onAppear()
        relaunched.reconcileOrphanedCaptures()
        #expect(relaunched.jobs.count == 1)
        #expect(relaunched.jobs.first?.id == accepted)
        #expect(journal.pendingHandoffs().isEmpty)
        #expect(relaunched.captureRecoveryIssues.isEmpty)
        #expect(try Data(contentsOf: files.captured) == bytes)
    }

    @Test func unreadableMarkerRetryRecoversExactlyOnePhoto() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let directory = files.directory.appendingPathComponent("journal")
        let journal = journal(files)
        try journal.markPending(files.captured, mediaKind: .photo)
        try journal.markValidated(files.captured, mediaKind: .photo)
        let marker = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        var saves: [URL] = []
        let model = RenderQueueViewModel(persistenceURL: files.queue,
            render: { _ in throw StillHandoffTestError.render }, save: { saves.append($0) },
            journal: journal, sessionId: launchSession)
        model.onAppear()
        #expect(model.jobs.isEmpty)
        #expect(saves.isEmpty)
        #expect(model.captureRecoveryIssues.count == 1)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        model.reconcileOrphanedCaptures()
        try await waitUntil { model.jobs.first?.status == .completed }
        model.reconcileOrphanedCaptures()
        #expect(model.captureRecoveryIssues.isEmpty)
        #expect(model.jobs.count == 1)
        #expect(saves == [files.captured])
        #expect(journal.pendingHandoffs().isEmpty)
    }

    @Test func captureCallersRequireTheMarkerBeforeHardwareAndDoNotPoisonValidatedDNG() throws {
        let photo = try String(contentsOf: TestRepository.url(
            for: "App/Modules/CameraCapture/CameraPhotoCapture.swift"), encoding: .utf8)
        let marker = try #require(photo.range(of: "try journal?.markPending"))
        let started = try #require(photo.range(of: "started = true"))
        let hardware = try #require(photo.range(of: "output.capturePhoto(with:"))
        #expect(marker.lowerBound < started.lowerBound)
        #expect(started.lowerBound < hardware.lowerBound)
        let validated = try #require(photo.range(of: "self.dngURL = url"))
        let upgraded = try #require(photo.range(of: "do { try self.journal?.markValidated"))
        let failed = try #require(photo.range(of: "} catch {\n                self.failure = self.failure ?? \"DNG validation failed:"))
        #expect(validated.lowerBound < upgraded.lowerBound)
        let warning = String(photo[upgraded.lowerBound..<failed.lowerBound])
        #expect(warning.contains("self.evidence[\"journalWarning\"]"))
        #expect(!warning.contains("self.failure ="))
        let video = try String(contentsOf: TestRepository.url(
            for: "App/Modules/CameraCapture/CameraViewModel.swift"), encoding: .utf8)
        let videoMarker = try #require(video.range(of: "try captureJournal.markPending"))
        let policy = try #require(video.range(of: "capturePolicies.record(sourceURL: outputURL"))
        let videoHardware = try #require(video.range(of: "session.startRecording(to: outputURL)"))
        #expect(videoMarker.lowerBound < policy.lowerBound)
        #expect(policy.lowerBound < videoHardware.lowerBound)
    }

    // MARK: - Durable evidence promotes a validated DNG whose marker upgrade failed

    @Test func failedValidatedMarkerUpgradePromotesTheDNGOnceFromDurableEvidence() async throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try writeDecodableDNG(files.captured)
        let policy = try #require(RenderCapturePolicy(60, sourceProfile: .hlgBT2020))
        let writer = journal(files, session: UUID())
        try writer.markPending(files.captured, capturePolicy: policy, mediaKind: .photo)
        // The reported failure: the validated-marker replacement is refused
        // while the DNG itself is already valid and finished.
        let journalRoot = files.directory.appendingPathComponent("journal")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journalRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalRoot.path) }
        var upgradeRefused = false
        do { try writer.markValidated(files.captured, mediaKind: .photo) }
        catch { upgradeRefused = true }
        #expect(upgradeRefused)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalRoot.path)
        #expect(writer.pendingHandoffs().first?.validated == false)

        // The camera's post-validation manifest is the second witness.
        try writeManifest(for: files.captured)
        #expect(writer.pendingHandoffs().first?.validated == true,
                "The second durable witness must promote, not quarantine.")

        var renders = 0
        var saves: [URL] = []
        let model = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in renders += 1; throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: journal(files, session: UUID()), sessionId: launchSession)
        model.onAppear()
        try await waitUntil { model.jobs.first?.status == .completed }

        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.isPhoto == true)
        #expect(model.jobs.first?.originalOnly == true)
        #expect(model.jobs.first?.capturePolicy == policy)
        #expect(renders == 0)
        #expect(saves == [files.captured])
        #expect(model.captureRecoveryIssues.isEmpty)
        #expect(try markerFiles(files).isEmpty, "Durable queue acceptance releases the marker.")

        // A second launch loads the durable job; nothing is promoted again.
        let relaunched = RenderQueueViewModel(
            persistenceURL: files.queue,
            render: { _ in renders += 1; throw StillHandoffTestError.render },
            save: { url in saves.append(url) },
            journal: journal(files, session: UUID()), sessionId: launchSession)
        relaunched.onAppear()
        relaunched.reconcileOrphanedCaptures()
        try await Task.sleep(for: .milliseconds(50))
        #expect(relaunched.jobs.count == 1)
        #expect(saves == [files.captured])
    }

    @Test func promotionRefusesStalePartialOrMismatchedEvidence() async throws {
        for corruption in PromotionCorruption.allCases {
            let (files, _) = try scratch()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            try writeDecodableDNG(files.captured)
            switch corruption {
            case .preValidationStatus:
                try writeManifest(for: files.captured, status: "capturing")
            case .validationFailedAfterWrite:
                try writeManifest(for: files.captured, status: "photoProcessed",
                                  overrides: ["dngReadable": "false", "failure": "DNG validation failed"])
            case .wrongByteCount:
                try writeManifest(for: files.captured, overrides: ["dngBytes": "17"])
            case .recordedFailure:
                try writeManifest(for: files.captured, overrides: ["failure": "capture failed"])
            case .wrongFileName:
                try writeManifest(for: files.captured, overrides: ["dng": "other.dng"])
            case .wrongRawType:
                try writeManifest(for: files.captured, overrides: ["actualFileType": "public.jpeg"])
            case .dimensionDisagreement:
                try writeManifest(for: files.captured, overrides: ["resolvedRawWidth": "512"])
            case .undecodableBytes:
                try Data(repeating: 0, count: 4096).write(to: files.captured)
                try writeManifest(for: files.captured)
            case .staleRecord:
                try writeManifest(for: files.captured)
                try writeDecodableDNG(files.captured)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: files.captured.path)
            }
            let writer = journal(files, session: UUID())
            try writer.markPending(files.captured, mediaKind: .photo)

            var saves = 0
            let model = RenderQueueViewModel(
                persistenceURL: files.queue,
                render: { _ in throw StillHandoffTestError.render },
                save: { _ in saves += 1 },
                journal: journal(files, session: UUID()), sessionId: launchSession)
            model.onAppear()
            try await Task.sleep(for: .milliseconds(40))

            #expect(model.jobs.isEmpty, "\(corruption) must not become a job.")
            #expect(saves == 0, "\(corruption) must not be delivered.")
            #expect(model.captureRecoveryIssues.count == 1, "\(corruption) stays visible.")
            #expect(model.captureRecoveryIssues.allSatisfy { !$0.retryable },
                    "\(corruption) must not promise an impossible retry.")
            #expect(try markerFiles(files).count == 1, "The original's only reference is kept.")
        }
    }

    @Test func recordedValidationFailureStaysVisibleWithoutPromotion() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([1, 2, 3, 4]).write(to: files.captured)
        try writeManifest(for: files.captured, status: "failed",
                          overrides: ["dngReadable": "false", "failure": "DNG validation failed"])
        let writer = journal(files, session: UUID())
        try writer.markPending(files.captured, mediaKind: .photo)
        let scan = journal(files, session: UUID()).scan()
        #expect(scan.handoffs.isEmpty)
        #expect(scan.issues.map(\.url) == [files.captured])
        #expect(scan.issues.allSatisfy { !$0.retryable })
        #expect(try markerFiles(files).count == 1)
    }

    // MARK: - Terminal missing bytes versus a live capture

    @Test func failedCaptureWithoutBytesIsClosedInsteadOfWarnedAbout() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.removeItem(at: files.captured)
        try writeManifest(for: files.captured, status: "failed", removing: ["dngReadable"],
                          overrides: ["dng": "missing", "failure": "capture failed: no data"])
        let writer = journal(files, session: UUID())
        try writer.markPending(files.captured, mediaKind: .photo)

        // A relaunch closes it from the capture's own terminal record.
        let recovery = journal(files, session: UUID())
        #expect(recovery.scan().handoffs.isEmpty)
        #expect(recovery.scan().issues.isEmpty)
        #expect(try markerFiles(files).isEmpty,
                "A provably failed capture is closed, not kept as a permanent warning.")

        // The same terminal proof closes a retry in the owning process too.
        let (realtime, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: realtime.directory) }
        try FileManager.default.removeItem(at: realtime.captured)
        try writeManifest(for: realtime.captured, status: "failed", removing: ["dngReadable"],
                          overrides: ["dng": "missing", "failure": "capture failed: no data"])
        let live = journal(realtime, session: UUID())
        try live.markPending(realtime.captured, mediaKind: .photo)
        #expect(live.scan().issues.isEmpty)
        #expect(try markerFiles(realtime).isEmpty)
    }

    @Test func missingCaptureFromAnEarlierProcessIsClosedQuietly() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.removeItem(at: files.captured)
        let writer = journal(files, session: UUID())
        try writer.markPending(files.captured, mediaKind: .photo)

        // No capture record: the owning process is gone, so no byte can arrive.
        let scan = journal(files, session: UUID()).scan()
        #expect(scan.handoffs.isEmpty)
        #expect(scan.issues.isEmpty, "No impossible retry promise for bytes that can never arrive.")
        #expect(try markerFiles(files).isEmpty)
    }

    @Test func retryBeforeStillBytesLandKeepsTheMarkerWithoutWarning() throws {
        let (files, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.removeItem(at: files.captured)
        let live = journal(files, session: UUID())
        try live.markPending(files.captured, mediaKind: .photo)

        #expect(live.scan().handoffs.isEmpty)
        #expect(live.scan().issues.isEmpty, "An in-flight capture is not a recovery problem.")
        #expect(try markerFiles(files).count == 1,
                "Retry must not erase the record before the bytes land.")

        // The live callback's atomic write and validation record land later.
        try writeDecodableDNG(files.captured)
        try writeManifest(for: files.captured)
        #expect(live.scan().handoffs.first?.validated == true)
        #expect(try markerFiles(files).count == 1)
    }

    // MARK: - More than one handoff in flight

    @Test func twoInFlightStillsKeepTheirOwnMarkers() throws {
        let (files, captures) = try scratch(stills: 2)
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let journal = journal(files)
        // Both stills are named `capture.dng`; only their folders differ.
        try journal.markPending(captures[0], mediaKind: .photo)
        try journal.markValidated(captures[0], mediaKind: .photo)
        try journal.markPending(captures[1], mediaKind: .photo)

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

/// One fact of a promotion record, corrupted in isolation.
private enum PromotionCorruption: CaseIterable, CustomStringConvertible {
    case preValidationStatus, validationFailedAfterWrite, wrongByteCount, recordedFailure
    case wrongFileName, wrongRawType, dimensionDisagreement, undecodableBytes, staleRecord

    var description: String {
        switch self {
        case .preValidationStatus: "pre-validation status"
        case .validationFailedAfterWrite: "validation failed after the write"
        case .wrongByteCount: "wrong byte count"
        case .recordedFailure: "recorded failure"
        case .wrongFileName: "different file named"
        case .wrongRawType: "wrong raw type"
        case .dimensionDisagreement: "dimension disagreement"
        case .undecodableBytes: "undecodable bytes"
        case .staleRecord: "record older than the file"
        }
    }
}

/// A minimal 256×256 16-bit Bayer DNG. Built here rather than checked in so the
/// acceptance test exercises the real ImageIO decode path without a binary
/// fixture. Tags mirror a camera DNG: CFA photometric, active area, crop, DNG
/// version and colour matrices.
private enum MinimalDNG {
    static func data(width: Int = 256, height: Int = 256) -> Data {
        var pixels = Data(capacity: width * height * 2)
        for index in 0..<(width * height) {
            var value = UInt16(truncatingIfNeeded: index &* 257)
            withUnsafeBytes(of: &value) { pixels.append(contentsOf: $0) }
        }
        return tiff(width: width, height: height, pixels: pixels)
    }

    private struct Entry {
        let tag: UInt16, type: UInt16, count: UInt32
        let payload: Data
    }

    private static func tiff(width: Int, height: Int, pixels: Data) -> Data {
        func short(_ value: UInt16) -> Data { withUnsafeBytes(of: value) { Data($0) } }
        func long(_ value: UInt32) -> Data { withUnsafeBytes(of: value) { Data($0) } }
        func shorts(_ values: [UInt16]) -> Data { values.reduce(Data()) { $0 + short($1) } }
        func longs(_ values: [UInt32]) -> Data { values.reduce(Data()) { $0 + long($1) } }
        func rationals(_ pairs: [(Int32, Int32)]) -> Data {
            pairs.reduce(Data()) {
                $0 + withUnsafeBytes(of: $1.0) { Data($0) } + withUnsafeBytes(of: $1.1) { Data($0) }
            }
        }
        var entries: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, payload: long(0)),
            Entry(tag: 256, type: 3, count: 1, payload: short(UInt16(width))),
            Entry(tag: 257, type: 3, count: 1, payload: short(UInt16(height))),
            Entry(tag: 258, type: 3, count: 1, payload: short(16)),
            Entry(tag: 259, type: 3, count: 1, payload: short(1)),
            Entry(tag: 262, type: 3, count: 1, payload: short(32803)),
            Entry(tag: 273, type: 4, count: 1, payload: Data(repeating: 0, count: 4)),
            Entry(tag: 274, type: 3, count: 1, payload: short(1)),
            Entry(tag: 277, type: 3, count: 1, payload: short(1)),
            Entry(tag: 278, type: 4, count: 1, payload: long(UInt32(height))),
            Entry(tag: 279, type: 4, count: 1, payload: long(UInt32(pixels.count))),
            Entry(tag: 284, type: 3, count: 1, payload: short(1)),
            Entry(tag: 33421, type: 3, count: 2, payload: shorts([2, 2])),
            Entry(tag: 33422, type: 1, count: 4, payload: Data([0, 1, 1, 2])),
            Entry(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
            Entry(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])),
            Entry(tag: 50708, type: 2, count: 11, payload: Data("TestCamera\0".utf8)),
            Entry(tag: 50710, type: 1, count: 3, payload: Data([0, 1, 2])),
            Entry(tag: 50711, type: 3, count: 1, payload: short(1)),
            Entry(tag: 50714, type: 5, count: 1, payload: rationals([(0, 1)])),
            Entry(tag: 50717, type: 4, count: 1, payload: long(65535)),
            Entry(tag: 50719, type: 4, count: 2, payload: longs([0, 0])),
            Entry(tag: 50720, type: 4, count: 2, payload: longs([UInt32(width), UInt32(height)])),
            Entry(tag: 50721, type: 10, count: 9, payload: rationals([
                (1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)
            ])),
            Entry(tag: 50728, type: 5, count: 3, payload: rationals([(1, 1), (1, 1), (1, 1)])),
            Entry(tag: 50778, type: 3, count: 1, payload: short(21)),
            Entry(tag: 50829, type: 4, count: 4, payload: longs([0, 0, UInt32(height), UInt32(width)])),
        ]
        entries.sort { $0.tag < $1.tag }
        let ifdOffset: UInt32 = 8
        let ifdSize = 2 + entries.count * 12 + 4
        var extra = Data()
        var ifd = Data()
        ifd.append(short(UInt16(entries.count)))
        var stripEntry: Int?
        for (index, entry) in entries.enumerated() {
            ifd.append(short(entry.tag))
            ifd.append(short(entry.type))
            ifd.append(long(entry.count))
            if entry.tag == 273 {
                stripEntry = index
                ifd.append(Data(repeating: 0, count: 4))
            } else if entry.payload.count <= 4 {
                ifd.append(entry.payload)
                ifd.append(Data(repeating: 0, count: 4 - entry.payload.count))
            } else {
                ifd.append(long(ifdOffset + UInt32(ifdSize) + UInt32(extra.count)))
                extra.append(entry.payload)
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }
        ifd.append(long(0))
        var output = Data("II".utf8) + short(42) + long(ifdOffset) + ifd + extra
        if output.count % 2 == 1 { output.append(0) }
        if let stripEntry {
            let position = 8 + 2 + stripEntry * 12 + 8
            output.replaceSubrange(position..<position + 4, with: long(UInt32(output.count)))
        }
        output.append(pixels)
        return output
    }
}
