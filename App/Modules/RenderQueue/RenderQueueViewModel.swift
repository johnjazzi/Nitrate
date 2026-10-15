import Observation
import Photos
import AVFoundation
import ImageIO
import CoreGraphics

/// Owns one serial chain of rendering and Photos delivery work.
@MainActor
@Observable
final class RenderQueueViewModel {
    typealias RenderOperation = @MainActor (RenderJob) async throws -> URL
    typealias SaveOperation = @MainActor (URL) async throws -> Void
    typealias PostDeliveryOperation = @MainActor (URL, UUID) async -> Void

    private let persister: QueuePersister
    private let injectedRender: RenderOperation?
    private let saveOperation: SaveOperation
    private let postDeliveryOperation: PostDeliveryOperation?
    private var worker: Task<Void, Never>?
    private var renderer: PipelineRenderer?
    private var didInitialize = false
    private var persistenceErrorMessage: String?
    private var loadErrorMessage: String?
    private var canPersist = true
    private let sessionId: String

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

    init(persistenceURL: URL? = nil, render: RenderOperation? = nil, save: SaveOperation? = nil,
         postDelivery: PostDeliveryOperation? = nil,
         sessionId: String = RenderJob.currentSessionId) {
        persister = QueuePersister(storageURL: persistenceURL)
        injectedRender = render
        saveOperation = save ?? Self.saveToPhotoLibrary
        postDeliveryOperation = postDelivery
        self.sessionId = sessionId
    }

    func onAppear() {
        guard !didInitialize else { return }
        didInitialize = true
        initializeRenderer()
        do {
            let persisted = try persister.load()
            jobs = persisted.map { job in
                var recovered = job
                if recovered.status == .processing {
                    recovered.status = .pending
                    recovered.sessionId = sessionId
                }
                return recovered
            }
        } catch {
            canPersist = false
            loadErrorMessage = "Queue state could not be loaded: \(error.localizedDescription)"
            publishQueueMessage()
            return
        }
        processNext()
    }

    func enqueue(sourceURL: URL, stockId: String, iso: Float, gauge: PrintGauge? = nil,
                 deliveryPreferences: RenderDeliveryPreferences? = nil) {
        guard Self.isUsableFile(sourceURL) else {
            rendererErrorMessage = "Source video not ready. Try again."
            return
        }
        rendererErrorMessage = nil
        jobs.append(RenderJob(sourceURL: sourceURL, stockId: stockId, iso: iso,
                              printGauge: gauge, sessionId: sessionId,
                              deliveryPreferences: deliveryPreferences ?? DeliverySettings.renderPreferences()))
        persistJobs()
        processNext()
    }

    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].status == .failed else { return }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        jobs[index].sessionId = sessionId
        persistJobs()
        processNext()
    }

    func remove(jobId: UUID) {
        guard jobs.first(where: { $0.id == jobId })?.status != .processing else { return }
        jobs.removeAll { $0.id == jobId }
        persistJobs()
    }

    private var rendererInitError: String?

    private func initializeRenderer() {
        guard injectedRender == nil else { return }
        do { renderer = try PipelineRenderer() }
        catch { rendererInitError = error.localizedDescription }
    }

    private func persistJobs() {
        guard canPersist else {
            publishQueueMessage()
            return
        }
        do {
            try persister.save(jobs)
            persistenceErrorMessage = nil
            publishQueueMessage()
        } catch {
            persistenceErrorMessage = "Queue state could not be saved: \(error.localizedDescription)"
            publishQueueMessage()
        }
    }

    private func publishQueueMessage() {
        if let loadErrorMessage {
            rendererErrorMessage = loadErrorMessage
        } else if let persistenceErrorMessage {
            rendererErrorMessage = persistenceErrorMessage
        } else if let externalErrorMessage {
            rendererErrorMessage = externalErrorMessage
        } else if let failedMessage = currentSessionFailures.first?.errorMessage {
            rendererErrorMessage = failedMessage
        } else {
            rendererErrorMessage = nil
        }
    }

    private func processNext() {
        guard worker == nil, let job = jobs.first(where: { $0.status == .pending }) else { return }
        update(job.id) { $0.status = .processing; $0.errorMessage = nil; $0.sessionId = sessionId }
        persistJobs()
        worker = Task { [weak self] in
            guard let self else { return }
            await executeJob(job.id)
            worker = nil
            processNext()
        }
    }

    private func executeJob(_ jobId: UUID) async {
        guard let initial = job(jobId) else { return }
        // A confirmed Photos asset does not depend on the retained output file.
        // This also recovers a crash between the two requested deliveries.
        if initial.outputSavedToPhotos != true {
            do {
                var outputURL = initial.outputURL
                if let persistedOutput = outputURL, !Self.isUsableFile(persistedOutput) {
                    outputURL = nil
                    update(jobId) { $0.outputURL = nil; $0.outputSavedToPhotos = nil }
                    persistJobs()
                }
                if outputURL == nil {
                    outputURL = try await render(initial)
                    guard let url = outputURL, Self.isUsableFile(url) else {
                        throw QueueError.invalidOutput
                    }
                    update(jobId) { $0.outputURL = url }
                    persistJobs()
                }
                guard let outputURL, Self.isUsableFile(outputURL) else { throw QueueError.invalidOutput }
                try await saveOperation(outputURL)
                update(jobId) { $0.outputSavedToPhotos = true }
                // Persist the first success before attempting the original.
                persistJobs()
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
                persistJobs()
                return
            }
        }
        if initial.deliveryPreferences?.saveOriginalLog == true, job(jobId)?.sourceSavedToPhotos != true {
            do {
                // Deliver the capture file unchanged, including its Log encoding,
                // audio, orientation and custom metadata; never trim or delete it.
                try await saveOperation(initial.sourceURL)
                update(jobId) { $0.sourceSavedToPhotos = true }
                persistJobs()
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
                persistJobs()
                return
            }
        }
        update(jobId) { $0.status = .completed; $0.errorMessage = nil }
        persistJobs()
        if let outputURL = job(jobId)?.outputURL, Self.isUsableFile(outputURL) {
            if let postDeliveryOperation {
                await postDeliveryOperation(outputURL, jobId)
            } else {
                await dumpFrames(from: outputURL, jobId: jobId)
            }
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
        return try await renderer.render(sourceURL: job.sourceURL, config: config,
                                         trimRange: job.trimRange,
                                         bitrate: job.deliveryPreferences?.quality.averageBitRate ?? DeliverySettings.averageBitRate)
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

    /// Deliver a kept original to Photos unchanged.
    ///
    /// A take that failed validation is never rendered and never becomes a queue
    /// entry, but the readable file is still the user's footage, so it is saved
    /// verbatim. Runs off the render worker so it can neither disturb nor be
    /// blocked by the render queue.
    func saveOriginal(sourceURL: URL, reason: String) {
        guard Self.isUsableFile(sourceURL) else {
            externalErrorMessage = "The kept recording is no longer available to save "
                + "(\(reason))."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await saveOperation(sourceURL)
            } catch {
                externalErrorMessage = "Recording did not pass validation (\(reason)). "
                    + "Saving the original to Photos failed: \(error.localizedDescription). "
                    + "It remains in the app."
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout RenderJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
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
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }

    private nonisolated func dumpFrames(from url: URL, jobId: UUID) async {
        let asset = AVAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return }
        let times: [CMTime] = [CMTime(seconds: 0, preferredTimescale: 600),
                               CMTime(seconds: duration.seconds / 2, preferredTimescale: 600),
                               CMTime(seconds: max(0, duration.seconds - 0.1), preferredTimescale: 600)]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let frameDir = docs.appendingPathComponent("frames/\(jobId.uuidString)")
        try? FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        for (idx, time) in times.enumerated() {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
                  let destination = CGImageDestinationCreateWithURL(
                    frameDir.appendingPathComponent(["start", "middle", "end"][idx] + ".png") as CFURL,
                    "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
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
