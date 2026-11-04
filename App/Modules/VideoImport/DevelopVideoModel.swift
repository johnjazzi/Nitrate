import Foundation
import Observation

/// A picked clip moved into app-owned storage. The lease owns the file until a
/// durable queue acceptance transfers ownership to the render queue.
struct DevelopClipTransfer: Sendable {
    let lease: VideoImportFileLease
    let originalFilename: String

    var url: URL { lease.url }
}

/// Inline Develop model for the video-import mode.
///
/// Develop is inline, not modal: the model owns exactly one selected clip plus a
/// reference to the accepted render job, and the preview surface chooses the
/// clip. Rendering reuses the existing import service and render queue; the
/// model never decodes or reads media itself.
///
/// The type is platform-neutral so the real select / cancel / render lifecycle is
/// covered by native macOS tests. The PhotosPicker entry point lives in an
/// iOS-only extension (`DevelopVideoPicker.swift`).
@MainActor
@Observable
final class DevelopVideoModel {
    /// Moves the picked clip into app-owned storage. Supplied per selection by
    /// the platform layer; tests inject a deferred completion so the real
    /// transfer / inspect transitions are exercised rather than supplied state.
    typealias TransferOperation = @MainActor () async throws -> DevelopClipTransfer
    /// Validates a transferred clip. Injected at init so tests drive the inspect
    /// transition without a real Apple Log movie.
    typealias InspectOperation = @MainActor (_ url: URL, _ originalFilename: String) async throws -> ImportedVideo
    /// Moves a picked photo into app-owned storage, and validates it.
    typealias PhotoTransferOperation = @MainActor () async throws -> DevelopPhotoTransfer
    typealias PhotoInspectOperation = @MainActor (_ url: URL, _ originalFilename: String) async throws -> ImportedPhoto

    /// A picked photo moved into app-owned storage, the counterpart of `video`.
    /// Exactly one of the two is set.
    struct DevelopPhotoTransfer: Sendable {
        let lease: VideoImportFileLease
        let originalFilename: String

        var url: URL { lease.url }
    }

    private(set) var video: ImportedVideo?
    private(set) var photo: ImportedPhoto?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The accepted render job. Survives a new selection while it is pending or
    /// processing, so the preview keeps showing genuine render progress.
    private(set) var activeJobID: UUID?

    private let queue: RenderQueueViewModel
    private let inspect: InspectOperation
    private let inspectPhoto: PhotoInspectOperation
    @ObservationIgnored private var lease: VideoImportFileLease?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var transferProgress: Progress?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTransfer: (token: UUID, operation: TransferOperation)?
    @ObservationIgnored private var pendingPhotoTransfer: (token: UUID, operation: PhotoTransferOperation)?

    init(queue: RenderQueueViewModel,
         inspect: @escaping InspectOperation = { url, originalFilename in
             try await VideoImportService.inspect(url: url, originalFilename: originalFilename)
         },
         inspectPhoto: @escaping PhotoInspectOperation = { url, originalFilename in
             try await PhotoImportService.inspect(url: url, originalFilename: originalFilename)
         }) {
        self.queue = queue
        self.inspect = inspect
        self.inspectPhoto = inspectPhoto
    }

    // MARK: - Selection

    /// Starts a selection whose transfer result the caller supplies.
    ///
    /// The injected closure is the transfer seam: the iOS layer wraps
    /// `PhotosPickerItem` in it, and tests suspend it to drive the real
    /// begin → transfer → inspect → accept transitions.
    func select(transfer: @escaping TransferOperation) {
        // A new clip drops a prior job reference only once that job has settled;
        // a pending or processing render keeps its reference so the preview stays
        // covered while it runs.
        clearSettledJobReference()
        cancelSelection()
        let token = generation
        video = nil
        errorMessage = nil
        isLoading = true
        // The operation is held on the model with its token and read inside the
        // task, so no non-Sendable closure crosses the task boundary and a stale
        // task can never run a newer selection's transfer.
        pendingTransfer = (token, transfer)
        selectionTask = Task { @MainActor [weak self] in
            await self?.runSelection(token: token)
        }
    }

    /// The photo half of the same seam: pick, transfer, validate, accept. The
    /// picked image is only accepted once it is a raw file the still renderer can
    /// develop, and only then is it copied into app storage.
    func selectPhoto(transfer: @escaping PhotoTransferOperation) {
        clearSettledJobReference()
        cancelSelection()
        let token = generation
        photo = nil
        errorMessage = nil
        isLoading = true
        pendingPhotoTransfer = (token, transfer)
        selectionTask = Task { @MainActor [weak self] in
            await self?.runPhotoSelection(token: token)
        }
    }

    /// Cancel the in-flight transfer / inspection. The unqueued file is released
    /// by its lease; an already accepted queue job is never touched.
    func cancelSelection() {
        generation = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        pendingTransfer = nil
        pendingPhotoTransfer = nil
        transferProgress?.cancel()
        transferProgress = nil
        lease = nil
        isLoading = false
    }

    /// Leaves Develop without touching an accepted queue job. Only unqueued
    /// selection work is cancelled and the selected clip is dropped.
    func leaveDevelop() {
        cancelSelection()
        video = nil
        photo = nil
        errorMessage = nil
    }

    private func runPhotoSelection(token: UUID) async {
        guard let pending = pendingPhotoTransfer, pending.token == token else { return }
        let transfer = pending.operation
        do {
            let picked = try await transfer()
            guard token == generation else { return }
            let inspected = try await inspectPhoto(picked.url, picked.originalFilename)
            guard token == generation else { return }
            lease = picked.lease
            photo = inspected
            isLoading = false
            finish(token)
        } catch {
            guard token == generation else { return }
            lease = nil
            photo = nil
            isLoading = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Choose a raw photo that can be developed."
            finish(token)
        }
    }

    private func runSelection(token: UUID) async {
        guard let pending = pendingTransfer, pending.token == token else { return }
        let transfer = pending.operation
        do {
            let clip = try await transfer()
            // Stale results are fenced; the local lease deinitialises and discards
            // the unqueued file.
            guard token == generation else { return }
            let inspected = try await inspect(clip.url, clip.originalFilename)
            guard token == generation else { return }
            lease = clip.lease
            video = inspected
            isLoading = false
            finish(token)
        } catch {
            guard token == generation else { return }
            lease = nil
            video = nil
            isLoading = false
            errorMessage = "Choose an Apple Log 2 video that can be read on this device."
            finish(token)
        }
    }

    /// Clears the selection bookkeeping owned by this token only, so a newer
    /// selection's state is never clobbered.
    private func finish(_ token: UUID) {
        if pendingTransfer?.token == token { pendingTransfer = nil }
        transferProgress = nil
        selectionTask = nil
    }

    /// Publishes the platform transfer's live `Progress` so a superseded or
    /// abandoned selection cancels the underlying load.
    func attachTransferProgress(_ progress: Progress?) {
        transferProgress = progress
    }

    // MARK: - Rendering

    /// True when a clip is selected, a stock is chosen, and no render is already
    /// active. Prevents a duplicate active render.
    func canRender(stock: FilmStockConfig?, queue: RenderQueueViewModel) -> Bool {
        guard let stock, !stock.stockId.isEmpty else { return false }
        guard !isLoading else { return false }
        let selected = video?.url ?? photo?.url
        guard let selected, lease?.url == selected else { return false }
        return !isRenderActive(in: queue)
    }

    /// Enqueues the selected clip. Ownership transfers to the queue only after a
    /// durable acceptance returns an id; a failed enqueue keeps the selection so
    /// the user can retry.
    @discardableResult
    /// `pushPull` is the exposure the develop applies to the file's Apple Log 2
    /// code. A nil value falls back to the stock's persisted manual pull, so a
    /// developed import matches the camera's current setting rather than
    /// silently rendering neutral.
    func render(stock: FilmStockConfig, iso: Float, gauge: PrintGauge,
                pushPull: PushPullExposure? = nil,
                queue: RenderQueueViewModel) -> UUID? {
        guard canRender(stock: stock, queue: queue) else { return nil }
        if let photo {
            // A developed raw keeps its own exposure index when the file carries
            // one: the DNG recorded it, so the render states what was shot rather
            // than the stock's default.
            // `isImported: true` — this raw came from the operator's library, so
            // the job delivers the develop and nothing else. Saving an
            // "original" would duplicate what is already there, and for a maker's
            // raw the library will not take, it failed a render that succeeded.
            guard let id = queue.enqueuePhoto(sourceURL: photo.url, stockId: stock.stockId,
                                              iso: photo.iso ?? stock.defaultISO, gauge: gauge,
                                              cropZoom: 1, seed: Self.grainSeed(for: photo),
                                              pushPull: pushPull, isImported: true) else {
                errorMessage = queue.rendererErrorMessage ?? "Could not queue the photo. Try again."
                return nil
            }
            lease?.transferToQueue()
            lease = nil
            self.photo = nil
            errorMessage = nil
            activeJobID = id
            return id
        }
        guard let video else { return nil }
        guard let id = queue.enqueueImportedVideo(sourceURL: video.url, stockId: stock.stockId,
                                                  iso: iso, gauge: gauge, pushPull: pushPull) else {
            errorMessage = queue.rendererErrorMessage ?? "Could not queue the video. Try again."
            return nil
        }
        lease?.transferToQueue()
        lease = nil
        self.video = nil
        errorMessage = nil
        activeJobID = id
        return id
    }

    /// A stable grain seed per imported photo, so re-developing the same file
    /// reproduces the same grain instead of reshuffling it. Pure arithmetic, so
    /// it is not actor-isolated with the model.
    nonisolated static func grainSeed(for photo: ImportedPhoto) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in photo.url.lastPathComponent.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private func isRenderActive(in queue: RenderQueueViewModel) -> Bool {
        guard let id = activeJobID, let job = queue.jobs.first(where: { $0.id == id }) else { return false }
        return job.status == .pending || job.status == .processing
    }

    /// Drops the job reference only when the job is terminal or missing. A job
    /// that is still pending or processing keeps its reference.
    private func clearSettledJobReference() {
        guard let id = activeJobID else { return }
        guard let job = queue.jobs.first(where: { $0.id == id }) else {
            activeJobID = nil
            return
        }
        if job.status != .pending && job.status != .processing {
            activeJobID = nil
        }
    }
}
