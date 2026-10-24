import Observation
import Photos
import AVFoundation

/// Owns one serial chain of rendering and Photos delivery work.
@MainActor
@Observable
final class RenderQueueViewModel {
    typealias RenderOperation = @MainActor (RenderJob) async throws -> URL
    typealias SaveOperation = @MainActor (URL) async throws -> Void
    typealias PostDeliveryOperation = @MainActor (URL, UUID) async -> Void
    typealias ReceiptOperation = @MainActor (URL, Double?) async -> RenderReceipt

    private let persister: QueuePersister
    private let journal: CaptureJournal
    private let persistOverride: (([RenderJob]) throws -> Void)?
    private let loadOverride: (() throws -> [RenderJob])?
    private let injectedRender: RenderOperation?
    private let saveOperation: SaveOperation
    private let postDeliveryOperation: PostDeliveryOperation?
    private let receiptOperation: ReceiptOperation?
    private let mediaCleanup: RenderMediaCleanup
    private var worker: Task<Void, Never>?
    private var renderer: PipelineRenderer?
    private var didInitialize = false
    private var persistenceErrorMessage: String?
    private var loadErrorMessage: String?
    /// True while the queue is paused because a durable write failed. Rendering
    /// and Photos side effects do not resume until `resume()` records the write.
    private(set) var isPersistenceBlocked = false
    /// True while render jobs are held because the paid render feature is not
    /// available (an expired evaluation with no verified purchase). Recording is
    /// never gated: the take is captured and stays queued, so nothing is lost and
    /// it renders as soon as access returns.
    private(set) var isRenderPausedForAccess = false
    /// Injected by the app root. Rendering the film look is the paid feature.
    /// Defaults to allowed so tests and any unwired context behave as before.
    @ObservationIgnored var renderAllowed: @MainActor () -> Bool = { true }
    private static let renderPausedMessage =
        "Rendering the film look needs an active subscription. Your recordings are safe in the queue "
        + "and will render once you subscribe."
    private let sessionId: String
    // A failure is a new alert on each failed transition, including a retry of
    // the same job. The retained job list remains independent of acknowledgement.
    private var failureAlert: (jobId: UUID, eventId: UUID, message: String)?
    private var acknowledgedFailureEventId: UUID?
    private var presentedFailureEventId: UUID?

    var library: FilmStockLibrary?
    var jobs: [RenderJob] = []
    var rendererErrorMessage: String?
    var externalErrorMessage: String? {
        didSet { publishQueueMessage() }
    }
    var renderingUnavailableMessage: String?
    var isProcessing: Bool { worker != nil }
    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var outstandingCount: Int { jobs.filter { $0.status == .pending || $0.status == .processing }.count }
    var currentJob: RenderJob? { jobs.first { $0.status == .processing } }
    var currentSessionJobs: [RenderJob] { jobs.filter { $0.sessionId == sessionId } }
    var outstandingJobs: [RenderJob] { jobs.filter { $0.status == .pending || $0.status == .processing } }
    /// Captures waiting for a stock to be chosen. Not rendering work.
    var awaitingStockJobs: [RenderJob] { jobs.filter { $0.status == .awaitingStock } }
    var currentSessionResults: [RenderJob] {
        currentSessionJobs.filter { $0.status == .completed || $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var currentSessionFailures: [RenderJob] { currentSessionResults.filter { $0.status == .failed } }
    var historyJobs: [RenderJob] {
        jobs.filter { $0.status == .completed || $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var completedJobs: [RenderJob] { jobs.filter { $0.status == .completed } }

    func dismissRendererError() {
        if let presentedFailureEventId {
            acknowledgedFailureEventId = presentedFailureEventId
        }
        presentedFailureEventId = nil
        rendererErrorMessage = nil
    }

    func reportRenderError(_ message: String) {
        presentedFailureEventId = nil
        rendererErrorMessage = message
    }

    init(persistenceURL: URL? = nil, render: RenderOperation? = nil, save: SaveOperation? = nil,
         postDelivery: PostDeliveryOperation? = nil,
         persist: (([RenderJob]) throws -> Void)? = nil,
         load: (() throws -> [RenderJob])? = nil,
         receipt: ReceiptOperation? = nil,
         mediaCleanup: RenderMediaCleanup = RenderMediaCleanup(),
         journal: CaptureJournal = CaptureJournal(),
         sessionId: String = RenderJob.currentSessionId) {
        persister = QueuePersister(storageURL: persistenceURL)
        self.journal = journal
        persistOverride = persist
        loadOverride = load
        injectedRender = render
        saveOperation = save ?? Self.saveToPhotoLibrary
        postDeliveryOperation = postDelivery
        receiptOperation = receipt
        self.mediaCleanup = mediaCleanup
        self.sessionId = sessionId
    }

    func onAppear() {
        guard !didInitialize else { processNext(); return }
        didInitialize = true
        initializeRenderer()
        do {
            let persisted = try (loadOverride ?? { try self.persister.load() })()
            jobs = persisted.map { job in
                var recovered = job
                if recovered.isImportedVideo == true { recovered.receipt?.thumbnailJPEG = nil }
                if recovered.status == .processing {
                    recovered.status = .pending
                    recovered.sessionId = sessionId
                }
                return recovered
            }
        } catch {
            // An unreadable queue file must not brick recording, rendering and
            // rescue forever. Keep the bytes for inspection, then start a fresh
            // queue so the app still works and new takes can be delivered.
            let quarantined = persister.quarantine()
            let suffix = quarantined.map { " The unreadable file was kept as \($0.lastPathComponent)." } ?? ""
            loadErrorMessage = "Queue state could not be loaded: \(error.localizedDescription)" + suffix
            jobs = []
            publishQueueMessage()
        }
        reconcileOrphanedCaptures()
        processNext()
    }

    /// Rescue captures that were marked before recording but never accepted by
    /// the queue — the app died (or the queue was unreadable) in between.
    ///
    /// They are queued original-only: the take's validation outcome is unknown,
    /// so it is delivered verbatim and never rendered.
    func reconcileOrphanedCaptures() {
        let known = Set(jobs.map { $0.sourceURL.standardizedFileURL.path })
        for source in journal.pendingCaptures() {
            if known.contains(source.standardizedFileURL.path) {
                journal.acknowledge(source)
                continue
            }
            if enqueueOriginalOnly(sourceURL: source, reason: "recovered after an interrupted session") {
                journal.acknowledge(source)
            }
        }
    }

    @discardableResult
    func enqueueImportedVideo(sourceURL: URL, stockId: String, iso: Float, gauge: PrintGauge? = nil,
                              preferences: RenderDeliveryPreferences? = nil) -> UUID? {
        guard !isPersistenceBlocked else { publishQueueMessage(); return nil }
        guard Self.isUsableFile(sourceURL) else {
            reportRenderError("The imported video could not be read. Choose it again.")
            return nil
        }
        if let existing = jobs.first(where: { $0.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL }) {
            return existing.isImportedVideo == true ? existing.id : nil
        }
        var delivery = preferences ?? DeliverySettings.renderPreferences()
        delivery.saveOriginalLog = false
        var imported = RenderJob(sourceURL: sourceURL, stockId: stockId, iso: iso, printGauge: gauge,
                                 sessionId: sessionId, deliveryPreferences: delivery)
        imported.isImportedVideo = true
        jobs.append(imported)
        guard persistJobs() else {
            jobs.removeAll { $0.id == imported.id }
            isPersistenceBlocked = true
            publishQueueMessage()
            return nil
        }
        processNext()
        return imported.id
    }

    func enqueue(sourceURL: URL, stockId: String, iso: Float, gauge: PrintGauge? = nil,
                 deliveryPreferences: RenderDeliveryPreferences? = nil,
                 capturePolicy: RenderCapturePolicy? = nil) {
        guard Self.isUsableFile(sourceURL) else {
            reportRenderError("Source video not ready. Try again.")
            return
        }
        if let awaiting = awaitingStockJobs.first(where: { $0.sourceURL == sourceURL }) {
            assignStock(jobId: awaiting.id, stockId: stockId, iso: iso, gauge: gauge,
                        deliveryPreferences: deliveryPreferences, capturePolicy: capturePolicy)
            return
        }
        rendererErrorMessage = nil
        jobs.append(RenderJob(sourceURL: sourceURL, stockId: stockId, iso: iso,
                              printGauge: gauge, sessionId: sessionId,
                              deliveryPreferences: deliveryPreferences ?? DeliverySettings.renderPreferences(),
                              capturePolicy: capturePolicy))
        // The enqueue must be durable before any render or Photos side effect.
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        journal.acknowledge(sourceURL)
        processNext()
    }

    /// Durably queue a take captured before a stock was chosen.
    ///
    /// The entry exists before the stock sheet is shown, so leaving the sheet
    /// (Done/swipe), taking another clip, or relaunching cannot strand it. It is
    /// discoverable in the queue and resumable with `assignStock` or
    /// `exportOriginal`. It is never rendered until a stock is assigned.
    @discardableResult
    func enqueueAwaitingStock(sourceURL: URL, deliveryPreferences: RenderDeliveryPreferences? = nil,
                              capturePolicy: RenderCapturePolicy? = nil) -> UUID? {
        guard Self.isUsableFile(sourceURL) else {
            reportRenderError("Source video not ready. Try again.")
            return nil
        }
        rendererErrorMessage = nil
        var job = RenderJob(awaitingStockSourceURL: sourceURL, sessionId: sessionId)
        job.deliveryPreferences = deliveryPreferences ?? DeliverySettings.renderPreferences()
        job.capturePolicy = capturePolicy
        jobs.append(job)
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return job.id
        }
        journal.acknowledge(sourceURL)
        publishQueueMessage()
        return job.id
    }

    /// Assign a stock to an awaiting entry and let it render.
    func assignStock(jobId: UUID, stockId: String, iso: Float, gauge: PrintGauge? = nil,
                     deliveryPreferences: RenderDeliveryPreferences? = nil,
                     capturePolicy: RenderCapturePolicy? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .awaitingStock else { return }
        jobs[index].stockId = stockId
        jobs[index].iso = iso
        jobs[index].printGauge = gauge
        if let deliveryPreferences { jobs[index].deliveryPreferences = deliveryPreferences }
        // The capture policy is snapshotted at enqueue/take start and read by the
        // renderer, never re-read from live UI. Assigning a stock must not
        // overwrite it; a policy argument is only adopted when none was captured.
        if jobs[index].capturePolicy == nil, let capturePolicy {
            jobs[index].capturePolicy = capturePolicy
        }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        jobs[index].sessionId = sessionId
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        processNext()
    }

    /// Deliver an awaiting entry's kept original to Photos without rendering it.
    func exportOriginal(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].isImportedVideo != true,
              jobs[index].status == .awaitingStock || jobs[index].originalOnly == true else { return }
        jobs[index].originalOnly = true
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        jobs[index].sessionId = sessionId
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        processNext()
    }

    /// Durably queue a kept original that failed validation for verbatim Photos
    /// delivery. It is never rendered, and the reason is retained.
    ///
    /// Returns whether the entry was durably recorded; the caller must only clear
    /// its handoff when this returns true.
    @discardableResult
    func enqueueOriginalOnly(sourceURL: URL, reason: String) -> Bool {
        guard !sourceURL.lastPathComponent.hasPrefix("clip_import_"),
              !jobs.contains(where: { $0.sourceURL == sourceURL && $0.isImportedVideo == true }) else { return false }
        guard Self.isUsableFile(sourceURL) else {
            externalErrorMessage = "The kept recording is no longer available to save "
                + "(\(reason))."
            return false
        }
        rendererErrorMessage = nil
        // The camera keeps its handoff until persistence succeeds. A repeated
        // acceptance attempt must reuse that source's original-only job.
        if !jobs.contains(where: { $0.sourceURL == sourceURL && $0.originalOnly == true }) {
            jobs.append(RenderJob(originalOnlySourceURL: sourceURL, reason: reason, sessionId: sessionId))
        }
        let accepted = persistJobs()
        if !accepted { isPersistenceBlocked = true }
        if accepted { journal.acknowledge(sourceURL) }
        publishQueueMessage()
        processNext()
        return accepted
    }

    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].status == .failed else { return }
        if failureAlert?.jobId == jobId {
            failureAlert = nil
            presentedFailureEventId = nil
        }
        if jobs[index].isDiscardingImport { requestImportDiscard(at: index); return }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        jobs[index].sessionId = sessionId
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        processNext()
    }

    /// Retry the durable write and continue the queue. The queued media is never
    /// touched; only the transition that failed to persist is re-attempted.
    func resume() {
        guard isPersistenceBlocked else { return }
        guard persistJobs(allowWhileBlocked: true) else { return }
        isPersistenceBlocked = false
        publishQueueMessage()
        processNext()
    }

    /// Access to the paid render feature changed (a purchase, a restore, or an
    /// evaluation that ended). Release anything held for access and re-evaluate.
    func renderAccessDidChange() {
        retryMediaCleanup()
        if renderAllowed() {
            isRenderPausedForAccess = false
            publishQueueMessage()
            processNext()
        } else {
            isRenderPausedForAccess = jobs.contains { $0.status == .pending && $0.originalOnly != true }
            publishQueueMessage()
        }
    }

    func remove(jobId: UUID) {
        guard jobs.first(where: { $0.id == jobId })?.status != .processing else { return }
        if failureAlert?.jobId == jobId {
            failureAlert = nil
            presentedFailureEventId = nil
        }
        if let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].isImportedVideo == true {
            requestImportDiscard(at: index)
            return
        }
        jobs.removeAll { $0.id == jobId }
        persistJobs()
    }

    private func requestImportDiscard(at index: Int) {
        jobs[index].discardImportedMedia = true
        jobs[index].status = .failed
        jobs[index].errorMessage = "Removing imported video…"
        jobs[index].cleanupWarning = nil
        guard persistJobs() else {
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        retryMediaCleanup()
    }

    private var rendererInitError: String?

    private func initializeRenderer() {
        guard injectedRender == nil else { return }
        do { renderer = try PipelineRenderer() }
        catch { rendererInitError = error.localizedDescription }
    }

    /// Persist the queue. Returns false when a durable write failed, so callers
    /// can pause further side effects rather than acting on unrecorded state.
    @discardableResult
    private func persistJobs(allowWhileBlocked: Bool = false) -> Bool {
        guard allowWhileBlocked || !isPersistenceBlocked else { return false }
        for index in jobs.indices where jobs[index].isImportedVideo == true {
            jobs[index].receipt?.thumbnailJPEG = nil
        }
        do {
            if let persistOverride { try persistOverride(jobs) } else { try persister.save(jobs) }
            persistenceErrorMessage = nil
            publishQueueMessage()
            return true
        } catch {
            persistenceErrorMessage = "Queue state could not be saved: \(error.localizedDescription)"
            publishQueueMessage()
            return false
        }
    }

    private func publishQueueMessage() {
        presentedFailureEventId = nil
        if let loadErrorMessage {
            rendererErrorMessage = loadErrorMessage
        } else if let persistenceErrorMessage {
            rendererErrorMessage = persistenceErrorMessage
        } else if let externalErrorMessage {
            rendererErrorMessage = externalErrorMessage
        } else if isRenderPausedForAccess {
            rendererErrorMessage = Self.renderPausedMessage
        } else if let failureAlert,
                  acknowledgedFailureEventId != failureAlert.eventId,
                  jobs.contains(where: { $0.id == failureAlert.jobId && $0.status == .failed && $0.sessionId == sessionId }) {
            rendererErrorMessage = failureAlert.message
            presentedFailureEventId = failureAlert.eventId
        } else {
            rendererErrorMessage = nil
        }
    }

    /// Pause the queue after a durable transition failed. The job returns to
    /// pending so `resume()` re-runs it; its in-memory delivery outcomes are kept
    /// so an already-confirmed side effect is not repeated.
    private func pauseAfterDurableFailure(_ jobId: UUID) {
        update(jobId) { $0.status = .pending }
        isPersistenceBlocked = true
        publishQueueMessage()
    }

    /// Persist a terminal failure. If it cannot be recorded, pause the queue so
    /// no further job runs on state that would be lost on relaunch.
    private func recordFailureState() {
        if !persistJobs() {
            isPersistenceBlocked = true
            publishQueueMessage()
        }
    }

    private func processNext(allowCleanup: Bool = true) {
        guard !isPersistenceBlocked else { return }
        guard worker == nil else { return }
        guard let job = jobs.first(where: { $0.status == .pending && !$0.isDiscardingImport }) else {
            isRenderPausedForAccess = false
            // A removal requested while this worker was suspended gets one sweep.
            // A failed unlink sets a warning and waits for Retry or activation.
            if allowCleanup || jobs.contains(where: { $0.isDiscardingImport && $0.cleanupWarning == nil }) {
                retryMediaCleanup()
            }
            return
        }
        // Delivering a kept original is not the paid feature, so a rescue job
        // always runs. Only rendering the film look is gated.
        if job.originalOnly != true || job.isImportedVideo == true, !renderAllowed() {
            isRenderPausedForAccess = true
            publishQueueMessage()
            return
        }
        isRenderPausedForAccess = false
        update(job.id) { $0.status = .processing; $0.errorMessage = nil; $0.sessionId = sessionId }
        guard persistJobs() else {
            update(job.id) { $0.status = .pending }
            isPersistenceBlocked = true
            publishQueueMessage()
            return
        }
        worker = Task { [weak self] in
            guard let self else { return }
            await executeJob(job.id)
            await cleanupDeliveredMedia()
            worker = nil
            processNext(allowCleanup: false)
        }
    }

    /// Activation/relaunch retries cleanup only, never a completed Photos save.
    /// Shares the serial worker with delivery so enqueueing cannot race an unlink.
    func retryMediaCleanup() {
        guard worker == nil, !isPersistenceBlocked,
              jobs.contains(where: Self.needsMediaCleanup) else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await cleanupDeliveredMedia()
            worker = nil
            processNext(allowCleanup: false)
        }
    }

    private static func needsMediaCleanup(_ job: RenderJob) -> Bool {
        if job.isDiscardingImport { return true }
        guard job.status == .completed, job.receipt != nil,
              job.mediaCleanupCompleted != true else { return false }
        if job.originalOnly == true, job.isImportedVideo != true { return job.sourceSavedToPhotos == true }
        return job.outputSavedToPhotos == true
            && (!job.shouldSaveOriginal || job.sourceSavedToPhotos == true)
    }

    private func ensureReceipt(_ id: UUID, url: URL) async -> Bool {
        guard job(id)?.receipt == nil else { return true }
        let receipt = await captureReceipt(id, url: url, elapsed: nil)
        update(id) { $0.receipt = receipt }
        guard persistJobs() else { pauseAfterDurableFailure(id); return false }
        return true
    }

    private func captureReceipt(_ id: UUID, url: URL, elapsed: Double?) async -> RenderReceipt {
        let imported = job(id)?.isImportedVideo == true
        var receipt: RenderReceipt
        if let receiptOperation {
            receipt = await receiptOperation(url, elapsed)
        } else {
            receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: elapsed,
                                                         includeThumbnail: !imported)
        }
        if imported { receipt.thumbnailJPEG = nil }
        return receipt
    }

    private func cleanupDeliveredMedia() async {
        guard !isPersistenceBlocked else { return }
        let candidates = jobs.filter(Self.needsMediaCleanup).map(\.id)
        guard !candidates.isEmpty else { return }
        // Reconfirm delivery or an explicit import-discard request on disk
        // before crossing the destructive boundary, including after relaunch.
        guard persistJobs() else { isPersistenceBlocked = true; return }
        for id in candidates {
            guard !isPersistenceBlocked, let current = job(id), Self.needsMediaCleanup(current) else { continue }
            if !current.isDiscardingImport, let output = current.outputURL,
               Self.isUsableFile(output), let postDeliveryOperation {
                await postDeliveryOperation(output, id)
            }
            // A diagnostic may suspend while a new consumer is enqueued. Resolve
            // both roles and protections from the current queue, not a snapshot.
            guard !isPersistenceBlocked, let latest = job(id), Self.needsMediaCleanup(latest) else { continue }
            var allRemoved = true
            var warnings: [String] = []
            let urls = [latest.sourceURL] + [latest.outputURL].compactMap { $0 }
            for url in urls {
                let path = RenderMediaCleanup.canonicalPath(url)
                let protected = jobs.contains { other in
                    guard other.id != id, !other.isDiscardingImport,
                          !Self.isFullyDeliveredReceipt(other) else { return false }
                    return ([other.sourceURL] + [other.outputURL].compactMap { $0 }).contains {
                        RenderMediaCleanup.canonicalPath($0) == path
                    }
                }
                if protected {
                    allRemoved = false
                    warnings.append("Local movie is still needed by another queue entry.")
                    continue
                }
                do {
                    if try mediaCleanup.removeIfOwned(url) {
                        update(id) { if $0.outputURL == url { $0.outputURL = nil } }
                    } else {
                        allRemoved = false
                        warnings.append("Local movie was not removed because its app ownership could not be verified.")
                    }
                } catch {
                    allRemoved = false
                    warnings.append("Local movie cleanup failed: \(error.localizedDescription)")
                }
            }
            if latest.isDiscardingImport, allRemoved {
                jobs.removeAll { $0.id == id }
            } else {
                update(id) {
                    $0.mediaCleanupCompleted = allRemoved
                    $0.cleanupWarning = warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " ")
                    if latest.isDiscardingImport { $0.errorMessage = "Could not remove the imported video. Try again." }
                }
            }
            // Cleanup write failure never changes delivery into a retry. Missing
            // files are safe on the next launch; confirmed save flags stay set.
            guard persistJobs() else { isPersistenceBlocked = true; return }
        }
    }

    private static func isFullyDeliveredReceipt(_ job: RenderJob) -> Bool {
        guard job.status == .completed, job.receipt != nil else { return false }
        if job.originalOnly == true, job.isImportedVideo != true { return job.sourceSavedToPhotos == true }
        return job.outputSavedToPhotos == true
            && (!job.shouldSaveOriginal || job.sourceSavedToPhotos == true)
    }

    private func executeJob(_ jobId: UUID) async {
        guard let initial = job(jobId) else { return }

        // A kept original is delivered verbatim and never rendered, on this run
        // or any relaunch.
        if initial.originalOnly == true, initial.isImportedVideo != true {
            await deliverOriginalOnly(jobId)
            return
        }

        // A confirmed Photos asset does not depend on the retained output file.
        // This also recovers a crash between the two requested deliveries.
        if initial.outputSavedToPhotos != true {
            do {
                var outputURL = initial.outputURL
                if let persistedOutput = outputURL, !Self.isUsableFile(persistedOutput) {
                    outputURL = nil
                    update(jobId) { $0.outputURL = nil; $0.outputSavedToPhotos = nil }
                    guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
                }
                if outputURL == nil {
                    let started = ProcessInfo.processInfo.systemUptime
                    outputURL = try await render(initial)
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    guard let url = outputURL, Self.isUsableFile(url) else {
                        throw QueueError.invalidOutput
                    }
                    let receipt = await captureReceipt(jobId, url: url, elapsed: elapsed)
                    update(jobId) { $0.outputURL = url; $0.receipt = receipt }
                    guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
                }
                guard let outputURL, Self.isUsableFile(outputURL) else { throw QueueError.invalidOutput }
                guard await ensureReceipt(jobId, url: outputURL) else { return }
                try await saveOperation(outputURL)
                update(jobId) { $0.outputSavedToPhotos = true }
                // Persist the first success before attempting the original.
                guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
            } catch {
                if let outputURL = job(jobId)?.outputURL {
                    let message = Self.isUsableFile(outputURL)
                        ? "Rendered movie is retained for retry, but Photos save failed: \(error.localizedDescription)"
                        : "Rendered movie is unavailable and Photos save failed: \(error.localizedDescription)"
                    update(jobId) {
                        $0.status = .failed
                        $0.outputSavedToPhotos = false
                        $0.errorMessage = message
                    }
                } else {
                    await failRender(jobId, error: error)
                }
                recordFailureState()
                return
            }
        }
        if initial.shouldSaveOriginal, job(jobId)?.sourceSavedToPhotos != true {
            do {
                // Deliver the capture file unchanged, including its Log encoding,
                // audio, orientation and custom metadata; cleanup follows full delivery.
                try await saveOperation(initial.sourceURL)
                update(jobId) { $0.sourceSavedToPhotos = true }
                guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
            } catch {
                let sourceDetail = Self.isUsableFile(initial.sourceURL)
                    ? "Original remains in the app."
                    : "Original source is no longer available in the app."
                let outputDetail = job(jobId)?.outputURL.map(Self.isUsableFile) == true
                    ? "Rendered movie is retained in the app."
                    : "Rendered movie is no longer available in the app."
                update(jobId) {
                    $0.status = .failed
                    $0.sourceSavedToPhotos = false
                    $0.errorMessage = "Rendered movie saved to Photos, but original Apple Log could not be saved: \(error.localizedDescription). \(sourceDetail) \(outputDetail) Retry saves only the original."
                }
                recordFailureState()
                return
            }
        }
        if let output = job(jobId)?.outputURL, Self.isUsableFile(output) {
            guard await ensureReceipt(jobId, url: output) else { return }
        }
        update(jobId) { $0.status = .completed; $0.errorMessage = nil }
        guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
    }

    /// Deliver a kept original to Photos unchanged, without rendering it.
    private func deliverOriginalOnly(_ jobId: UUID) async {
        guard let job = job(jobId), job.isImportedVideo != true else { return }
        if job.sourceSavedToPhotos == true {
            if Self.isUsableFile(job.sourceURL) {
                guard await ensureReceipt(jobId, url: job.sourceURL) else { return }
            }
            update(jobId) { $0.status = .completed; $0.errorMessage = nil }
            guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
            return
        }
        let reasonSuffix = job.retainedReason.map { " (\($0))" } ?? ""
        guard Self.isUsableFile(job.sourceURL) else {
            update(jobId) {
                $0.status = .failed
                $0.sourceSavedToPhotos = false
                $0.errorMessage = "The kept recording is no longer available to save\(reasonSuffix)."
            }
            recordFailureState()
            return
        }
        do {
            guard await ensureReceipt(jobId, url: job.sourceURL) else { return }
            try await saveOperation(job.sourceURL)
            update(jobId) { $0.status = .completed; $0.sourceSavedToPhotos = true; $0.errorMessage = nil }
            guard persistJobs() else { pauseAfterDurableFailure(jobId); return }
        } catch {
            update(jobId) {
                $0.status = .failed
                $0.sourceSavedToPhotos = false
                $0.errorMessage = "Recording did not pass validation\(reasonSuffix). "
                    + "Saving the original to Photos failed: \(error.localizedDescription). "
                    + "It remains in the app."
            }
            recordFailureState()
        }
    }

    private func render(_ job: RenderJob) async throws -> URL {
        if let injectedRender { return try await injectedRender(job) }
        guard let renderer else {
            throw QueueError.rendererUnavailable(rendererInitError ?? "Metal pipeline could not start. Reboot the app.")
        }
        guard let config = library?.config(for: job.stockId, iso: job.iso, gauge: job.printGauge) else {
            throw QueueError.stockUnavailable(job.stockId)
        }
        // The render reads only the job's persisted policy, never live UI.
        return try await renderer.render(sourceURL: job.sourceURL, config: config,
                                         trimRange: job.trimRange,
                                         bitrate: job.deliveryPreferences?.quality.averageBitRate ?? DeliverySettings.averageBitRate,
                                         capturePolicy: job.capturePolicy,
                                         isImportedSource: job.isImportedVideo == true)
    }

    private func failRender(_ jobId: UUID, error: Error) async {
        let renderMessage = error.localizedDescription
        if let queueError = error as? QueueError {
            switch queueError {
            case .rendererUnavailable(_), .stockUnavailable(_):
                renderingUnavailableMessage = renderMessage
            case .invalidOutput, .photosPermissionDenied:
                break
            }
        }
        if job(jobId)?.isImportedVideo == true {
            update(jobId) {
                $0.status = .failed
                $0.errorMessage = "Render failed: \(renderMessage)"
            }
            return
        }
        if job(jobId)?.sourceSavedToPhotos == true {
            update(jobId) {
                $0.status = .failed
                $0.errorMessage = "Render failed: \(renderMessage). Original Apple Log was already saved to Photos."
            }
            return
        }
        guard let sourceURL = job(jobId)?.sourceURL else { return }
        do {
            try await saveOperation(sourceURL)
            update(jobId) {
                $0.status = .failed
                $0.sourceSavedToPhotos = true
                $0.errorMessage = "Render failed: \(renderMessage). Original Apple Log saved to Photos."
            }
        } catch {
            let saveMessage = error.localizedDescription
            let sourceDetail = Self.isUsableFile(sourceURL)
                ? "Source remains in the app."
                : "Original source is no longer available in the app."
            update(jobId) {
                $0.status = .failed
                $0.sourceSavedToPhotos = false
                $0.errorMessage = "Render failed: \(renderMessage). Original Apple Log could not be saved to Photos: \(saveMessage). \(sourceDetail)"
            }
        }
    }

    private func job(_ id: UUID) -> RenderJob? { jobs.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout RenderJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = jobs[index].status
        change(&jobs[index])
        if previousStatus != .failed, jobs[index].status == .failed,
           let message = jobs[index].errorMessage {
            failureAlert = (id, UUID(), message)
        }
    }

    private nonisolated static func isUsableFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 0
    }

    private nonisolated static func saveToPhotoLibrary(_ url: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorized: Bool
        switch status {
        case .authorized, .limited: authorized = true
        case .notDetermined: authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default: authorized = false
        }
        guard authorized else { throw QueueError.photosPermissionDenied }
        // The movie carries its own tag, so the asset gets the same short caption
        // as the file. No library read is involved.
        let tag = await RenderConsumerMetadata.tag(for: url)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            request.applyConsumerCaption(tag)
        }
    }

    enum QueueError: LocalizedError {
        case rendererUnavailable(String), stockUnavailable(String), invalidOutput, photosPermissionDenied
        var errorDescription: String? {
            switch self {
            case let .rendererUnavailable(reason): reason
            case let .stockUnavailable(stockId): "Film stock not found: \(stockId)"
            case .invalidOutput: "Render output file is empty or missing."
            case .photosPermissionDenied: "Photos add permission was denied."
            }
        }
    }
}

private extension PHAssetCreationRequest {
    /// Native Photos caption for the delivered asset. The same string is embedded
    /// in the movie, so an OS without this property still shows the tag from the
    /// file's own metadata.
    ///
    /// Keywords are deliberately NOT set here: Photos imports the movie's own
    /// keyword list into the asset, and adding the same keywords reports them
    /// twice in the Info panel. The embedded list stays the single source.
    func applyConsumerCaption(_ tag: RenderConsumerMetadata.Tag?) {
        guard let tag, #available(iOS 27.0, macOS 27.0, *) else { return }
        caption = tag.caption
    }
}
