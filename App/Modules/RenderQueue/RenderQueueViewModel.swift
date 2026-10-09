import Observation
import Photos
import AVFoundation
import UIKit

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
        if renderer == nil {
            rendererErrorMessage = rendererInitError ?? "Metal pipeline could not start. Reboot the app."
            Task { await saveToPhotoLibrary(sourceURL) }
            return
        }
        if library == nil || library?.config(for: stockId, iso: iso) == nil {
            rendererErrorMessage = "Film stock not found: \(stockId)"
            Task { await saveToPhotoLibrary(sourceURL) }
            return
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
            rendererErrorMessage = "Source video not ready. Try again."
            return
        }

        rendererErrorMessage = nil
        let job = RenderJob(sourceURL: sourceURL, stockId: stockId, iso: iso)
        jobs.append(job)
        persistJobs()
        processNext()
    }

    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        persistJobs()
        processNext()
    }

    func remove(jobId: UUID) {
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

        guard let renderer = renderer, let config = config else {
            jobs[index].status = .failed
            jobs[index].errorMessage = "Renderer or film stock library not ready."
            persistJobs()
            await saveToPhotoLibrary(job.sourceURL)
            processNext()
            return
        }

        do {
            let outputURL = try await renderer.render(sourceURL: job.sourceURL, config: config, trimRange: job.trimRange, bitrate: DeliverySettings.averageBitRate)

            guard FileManager.default.fileExists(atPath: outputURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                  let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
                jobs[index].status = .failed
                jobs[index].errorMessage = "Render output file is empty or missing."
                await saveToPhotoLibrary(job.sourceURL)
                persistJobs()
                processNext()
                return
            }

            jobs[index].status = .completed
            jobs[index].outputURL = outputURL

            await saveToPhotoLibrary(outputURL)
            await dumpFrames(from: outputURL, jobId: job.id)
        } catch {
            jobs[index].status = .failed
            jobs[index].errorMessage = error.localizedDescription
            await saveToPhotoLibrary(job.sourceURL)
        }

        persistJobs()
        processNext()
    }

    nonisolated private func saveToPhotoLibrary(_ url: URL) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorized: Bool
        switch status {
        case .authorized, .limited: authorized = true
        case .notDetermined: authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default: authorized = false
        }
        guard authorized else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// Extract 3 diagnostic frame stills (start / middle / end) from the rendered video.
    /// Saves PNGs to Documents/frames/<jobId>/ for Finder inspection.
    nonisolated private func dumpFrames(from url: URL, jobId: UUID) async {
        let asset = AVAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return }
        let times: [CMTime] = [
            CMTime(seconds: 0, preferredTimescale: 600),
            CMTime(seconds: duration.seconds / 2, preferredTimescale: 600),
            CMTime(seconds: max(0, duration.seconds - 0.1), preferredTimescale: 600)
        ]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let frameDir = docs.appendingPathComponent("frames/\(jobId.uuidString)")
        try? FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        for (idx, time) in times.enumerated() {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
                  let data = UIImage(cgImage: cgImage).pngData() else { continue }
            let name = ["start", "middle", "end"][idx]
            try? data.write(to: frameDir.appendingPathComponent("\(name).png"))
        }
    }
}