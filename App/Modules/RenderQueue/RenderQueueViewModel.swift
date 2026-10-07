import Observation
import Photos

/// AD-7: @Observable ViewModel managing the serial render queue.
/// Jobs are processed sequentially via OperationQueue. Queue persists across backgrounding.
@MainActor
@Observable
final class RenderQueueViewModel {
    private let persister = QueuePersister()
    private let queue = OperationQueue()
    private var renderer: PipelineRenderer?

    /// Injected film stock library — shared across the app, loaded once.
    var library: FilmStockLibrary?

    // MARK: - Observable State

    var jobs: [RenderJob] = []
    var rendererErrorMessage: String?
    var isProcessing: Bool { queue.operationCount > 0 }
    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var currentJob: RenderJob? { jobs.first { $0.status == .processing } }
    var completedJobs: [RenderJob] { jobs.filter { $0.status == .completed } }

    // MARK: - Actions

    func onAppear() {
        queue.maxConcurrentOperationCount = 1
        loadPersistedJobs()
        initializeRenderer()
    }

    /// Enqueue a new render job after recording completes.
    func enqueue(sourceURL: URL, stockId: String, iso: Float) {
        // Show a clear error if the pipeline never initialized.
        if renderer == nil {
            rendererErrorMessage = rendererInitError ?? "Metal pipeline could not start. Reboot the app."
            return
        }
        if library == nil || library?.config(for: stockId, iso: iso) == nil {
            rendererErrorMessage = "Film stock not found: \(stockId)"
            return
        }
        rendererErrorMessage = nil
        let job = RenderJob(sourceURL: sourceURL, stockId: stockId, iso: iso)
        jobs.append(job)
        persistJobs()
        processNext()
    }

    /// Retry a failed job.
    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        persistJobs()
        processNext()
    }

    /// Remove a job from the queue (completed or pending).
    func remove(jobId: UUID) {
        // Don't remove jobs that are currently processing
        guard jobs.first(where: { $0.id == jobId })?.status != .processing else { return }
        jobs.removeAll { $0.id == jobId }
        persistJobs()
    }

    // MARK: - Private

    private func initializeRenderer() {
        do {
            renderer = try PipelineRenderer()
        } catch {
            rendererInitError = error.localizedDescription
        }
    }

    private var rendererInitError: String?

    private func loadPersistedJobs() {
        if let persisted = try? persister.load() {
            jobs = persisted
        }
    }

    private func persistJobs() {
        try? persister.save(jobs)
    }

    private func processNext() {
        guard !isProcessing else { return }

        guard let index = jobs.firstIndex(where: { $0.status == .pending }) else { return }

        let job = jobs[index]
        jobs[index].status = .processing
        persistJobs()

        let capturedRenderer = renderer
        let capturedConfig = library?.config(for: job.stockId, iso: job.iso)

        queue.addOperation {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeJob(at: index, renderer: capturedRenderer, config: capturedConfig)
            }
        }
    }

    private func executeJob(at index: Int, renderer: PipelineRenderer?, config: FilmStockConfig?) async {
        let job = jobs[index]

        guard let renderer = renderer,
              let config = config else {
            jobs[index].status = .failed
            jobs[index].errorMessage = "Renderer or film stock library not ready."
            persistJobs()
            processNext()
            return
        }

        do {
            let outputURL = try await renderer.render(
                sourceURL: job.sourceURL,
                config: config,
                trimRange: job.trimRange
            )

            // Verify the output file actually exists and has data
            guard FileManager.default.fileExists(atPath: outputURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                  let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
                jobs[index].status = .failed
                jobs[index].errorMessage = "Render output file is empty or missing."
                persistJobs()
                processNext()
                return
            }

            jobs[index].status = .completed
            jobs[index].outputURL = outputURL

            // Save to camera roll via Photos framework
            await saveToPhotoLibrary(outputURL)
        } catch {
            jobs[index].status = .failed
            jobs[index].errorMessage = error.localizedDescription
        }

        persistJobs()
        processNext()
    }

    nonisolated private func saveToPhotoLibrary(_ url: URL) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorized: Bool
        switch status {
        case .authorized, .limited:
            authorized = true
        case .notDetermined:
            authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default:
            authorized = false
        }
        guard authorized else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            // Non-fatal: video is at the outputURL even if photo library save fails
        }
    }
}