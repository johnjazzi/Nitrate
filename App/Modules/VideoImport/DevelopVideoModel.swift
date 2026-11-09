import Foundation
import Observation

/// A transferred file remains leased until the durable queue accepts it.
struct DevelopClipTransfer: Sendable {
    let lease: VideoImportFileLease
    let originalFilename: String
    var url: URL { lease.url }
}

/// The shared import lease's legacy discard path only recognizes movies. Keep
/// that API unchanged, but give staged RAW copies the same bounded ownership
/// lifecycle. Construct only from a transferred app-owned copy, never adoption.
final class DevelopPhotoFileLease: @unchecked Sendable {
    private let imported: VideoImportFileLease
    private let lock = NSLock()
    private var queueOwnsFile = false
    var url: URL { imported.url }

    init(_ imported: VideoImportFileLease) { self.imported = imported }

    func transferToQueue() {
        lock.lock()
        queueOwnsFile = true
        lock.unlock()
        imported.transferToQueue()
    }

    deinit {
        lock.lock()
        let shouldDiscard = !queueOwnsFile
        lock.unlock()
        if shouldDiscard {
            let owned = imported.url
            Task.detached(priority: .utility) {
                let cleanup = RenderMediaCleanup(sourceRoot: owned.deletingLastPathComponent())
                _ = try? cleanup.removeIfOwned(owned, includeDevelopmentPhoto: true)
            }
        }
    }
}

/// Ordered originals used for review, never delivered outputs or preview files.
struct DevelopSource: Identifiable, Sendable, Equatable {
    let url: URL
    let originalFilename: String
    let isPhoto: Bool
    let iso: Float?
    let capturedOffsetEV: Float?
    let cropZoom: Double
    var id: String { url.absoluteString }
}

/// Stages imports and retained queue originals for the same explicit Develop action.
/// Only the existing queue owns rendering, delivery and accepted media.
@MainActor
@Observable
final class DevelopVideoModel {
    typealias TransferOperation = @MainActor () async throws -> DevelopClipTransfer
    typealias InspectOperation = @MainActor (_ url: URL, _ originalFilename: String) async throws -> ImportedVideo
    typealias PhotoTransferOperation = @MainActor () async throws -> DevelopPhotoTransfer
    typealias PhotoInspectOperation = @MainActor (_ url: URL, _ originalFilename: String) async throws -> ImportedPhoto

    struct DevelopPhotoTransfer: Sendable {
        let lease: VideoImportFileLease
        let originalFilename: String
        var url: URL { lease.url }
    }

    struct BulkDevelopResult: Sendable, Equatable {
        var queued = 0
        var skipped: [String] = []
    }

    struct BulkStaging {
        var photos: [ImportedPhoto] = []
        var videos: [ImportedVideo] = []
        var skipped: [String] = []
        var total = 0
        var read = 0
        @ObservationIgnored var photoLeases: [DevelopPhotoFileLease] = []
        @ObservationIgnored var videoLeases: [VideoImportFileLease] = []
        var count: Int { photos.count + videos.count }
        var isEmpty: Bool { count == 0 }
        var previewURL: URL? { photos.first?.url ?? videos.first?.url }
        var isPhotoStaging: Bool { videos.isEmpty && !photos.isEmpty }
    }

    private(set) var video: ImportedVideo?
    private(set) var photo: ImportedPhoto?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var bulk = BulkStaging()
    private(set) var adoptedURL: URL?
    private(set) var resultJobIDs: [UUID] = []
    // Compatibility projections: there is only one ordered accepted-job identity.
    var activeJobID: UUID? { resultJobIDs.first }
    var batchJobIDs: [UUID] { resultJobIDs }

    private var adoptedSources: [DevelopSource] = []
    private var workflowOrder: [URL] = []
    private let queue: RenderQueueViewModel
    private let inspect: InspectOperation
    private let inspectPhoto: PhotoInspectOperation
    @ObservationIgnored private var lease: VideoImportFileLease?
    @ObservationIgnored private var photoLease: DevelopPhotoFileLease?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var transferProgress: Progress?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTransfer: (token: UUID, operation: TransferOperation)?
    @ObservationIgnored private var pendingPhotoTransfer: (token: UUID, operation: PhotoTransferOperation)?

    init(queue: RenderQueueViewModel,
         inspect: @escaping InspectOperation = { url, name in
             try await VideoImportService.inspect(url: url, originalFilename: name)
         },
         inspectPhoto: @escaping PhotoInspectOperation = { url, name in
             try await PhotoImportService.inspect(url: url, originalFilename: name)
         }) {
        self.queue = queue
        self.inspect = inspect
        self.inspectPhoto = inspectPhoto
    }

    var sources: [DevelopSource] {
        if !adoptedSources.isEmpty { return adoptedSources }
        if !bulk.isEmpty {
            return bulk.photos.map(Self.source) + bulk.videos.map(Self.source)
        }
        if let photo { return [Self.source(photo)] }
        if let video { return [Self.source(video)] }
        return []
    }

    private static func source(_ photo: ImportedPhoto) -> DevelopSource {
        DevelopSource(url: photo.url, originalFilename: photo.originalFilename,
                      isPhoto: true, iso: photo.iso, capturedOffsetEV: nil, cropZoom: 1)
    }

    private static func source(_ video: ImportedVideo) -> DevelopSource {
        DevelopSource(url: video.url, originalFilename: video.originalFilename,
                      isPhoto: false, iso: nil, capturedOffsetEV: nil, cropZoom: 1)
    }

    var hasActiveRenders: Bool { isRenderActive(in: queue) }

    func canDevelop(stock: FilmStockConfig?) -> Bool {
        canRender(stock: stock, queue: queue)
    }

    func select(transfer: @escaping TransferOperation) {
        prepareSelection()
        let token = generation
        isLoading = true
        pendingTransfer = (token, transfer)
        selectionTask = Task { @MainActor [weak self] in await self?.runSelection(token: token) }
    }

    func selectPhoto(transfer: @escaping PhotoTransferOperation) {
        prepareSelection()
        let token = generation
        isLoading = true
        pendingPhotoTransfer = (token, transfer)
        selectionTask = Task { @MainActor [weak self] in await self?.runPhotoSelection(token: token) }
    }

    private func prepareSelection() {
        clearSettledJobReference()
        cancelSelection()
        errorMessage = nil
    }

    /// One and many picks use the same staging lifecycle. Check the token after
    /// EVERY suspension: a cancelled provider/inspector may still return a file.
    func stageVideos(transfers: [TransferOperation]) async {
        prepareSelection()
        let token = generation
        isLoading = true
        bulk.total = transfers.count
        for transfer in transfers {
            guard !Task.isCancelled, token == generation else { break }
            do {
                let picked = try await transfer()
                guard !Task.isCancelled, token == generation else { break }
                let inspected = try await inspect(picked.url, picked.originalFilename)
                guard !Task.isCancelled, token == generation else { break }
                bulk.videos.append(inspected)
                bulk.videoLeases.append(picked.lease)
            } catch {
                guard !Task.isCancelled, token == generation else { break }
                bulk.skipped.append((error as? LocalizedError)?.errorDescription ?? "One clip could not be read.")
            }
            bulk.read += 1
        }
        finishStaging(token)
    }

    func stagePhotos(transfers: [PhotoTransferOperation]) async {
        prepareSelection()
        let token = generation
        isLoading = true
        bulk.total = transfers.count
        for transfer in transfers {
            guard !Task.isCancelled, token == generation else { break }
            do {
                let picked = try await transfer()
                let held = DevelopPhotoFileLease(picked.lease)
                guard !Task.isCancelled, token == generation else { break }
                let inspected = try await inspectPhoto(picked.url, picked.originalFilename)
                guard !Task.isCancelled, token == generation else { break }
                bulk.photos.append(inspected)
                bulk.photoLeases.append(held)
            } catch {
                guard !Task.isCancelled, token == generation else { break }
                bulk.skipped.append((error as? LocalizedError)?.errorDescription ?? "One photo could not be read.")
            }
            bulk.read += 1
        }
        finishStaging(token)
    }

    private func finishStaging(_ token: UUID) {
        guard token == generation else { return }
        if Task.isCancelled { cancelSelection(); return }
        isLoading = false
        transferProgress = nil
        if bulk.isEmpty, let first = bulk.skipped.first {
            errorMessage = bulk.skipped.count == 1 ? first : "\(bulk.skipped.count) files could not be added. \(first)"
        }
    }

    @discardableResult
    func develop(stock: FilmStockConfig, iso: Float, gauge: PrintGauge,
                 pushPull: PushPullExposure) -> BulkDevelopResult {
        submit(stock: stock, iso: iso, gauge: gauge, pushPull: pushPull, queue: queue)
    }

    @discardableResult
    func commitBulk(stock: FilmStockConfig, gauge: PrintGauge, pushPull: PushPullExposure?,
                    queue: RenderQueueViewModel) -> BulkDevelopResult {
        submit(stock: stock, iso: stock.defaultISO, gauge: gauge, pushPull: pushPull, queue: queue)
    }

    /// Freeze the supplied recipe synchronously; release only accepted leases.
    /// Refused sources remain staged (including after a partial durable failure).
    private func submit(stock: FilmStockConfig, iso: Float, gauge: PrintGauge,
                        pushPull: PushPullExposure?, queue: RenderQueueViewModel) -> BulkDevelopResult {
        guard canRender(stock: stock, queue: queue) else { return BulkDevelopResult() }
        let selected = sources
        if workflowOrder.isEmpty { workflowOrder = selected.map(\.url) }
        var result = BulkDevelopResult(skipped: bulk.skipped)
        var accepted: [UUID] = []
        var acceptedURLs: Set<URL> = []
        for source in selected {
            let id: UUID?
            if let existing = queue.jobs.first(where: {
                $0.sourceURL.standardizedFileURL == source.url.standardizedFileURL
            }) {
                // A terminal queue job must really requeue, never deduplicate to
                // an old completed result. Preserve its capture/delivery recipe.
                id = queue.redevelopJobs(jobIds: [existing.id], stockId: stock.stockId,
                                         gauge: gauge, pushPull: pushPull) > 0 ? existing.id : nil
            } else if source.isPhoto, let imported = bulk.photos.first(where: { $0.url == source.url }) ?? photo {
                id = queue.enqueuePhoto(sourceURL: source.url, stockId: stock.stockId,
                                        iso: source.iso ?? iso, gauge: gauge, cropZoom: source.cropZoom,
                                        seed: Self.grainSeed(for: imported), pushPull: pushPull,
                                        isImported: true, retainsDevelopmentSource: true,
                                        originalFilename: source.originalFilename)
            } else if !source.isPhoto {
                id = queue.enqueueImportedVideo(sourceURL: source.url, stockId: stock.stockId,
                                                iso: source.iso ?? iso, gauge: gauge, pushPull: pushPull,
                                                retainsDevelopmentSource: true,
                                                originalFilename: source.originalFilename)
            } else {
                id = nil
            }
            if let id {
                if !accepted.contains(id) { accepted.append(id) }
                acceptedURLs.insert(source.url)
                transferLease(for: source.url)
                result.queued += 1
            } else {
                let reason = queue.rendererErrorMessage
                    ?? "The original is no longer on the device or is already developing."
                result.skipped.append("\(source.originalFilename): \(reason)")
            }
        }
        removeAcceptedSources(acceptedURLs)
        // Preserve accepted identity if a retry accepted nothing.
        if !accepted.isEmpty {
            for id in accepted where !resultJobIDs.contains(id) { resultJobIDs.append(id) }
            resultJobIDs.sort { left, right in
                let leftURL = queue.jobs.first { $0.id == left }?.sourceURL
                let rightURL = queue.jobs.first { $0.id == right }?.sourceURL
                return (workflowOrder.firstIndex { $0 == leftURL } ?? Int.max)
                    < (workflowOrder.firstIndex { $0 == rightURL } ?? Int.max)
            }
        }
        errorMessage = result.skipped.isEmpty ? nil : result.skipped.joined(separator: "\n")
        return result
    }

    private func transferLease(for url: URL) {
        if lease?.url == url { lease?.transferToQueue(); lease = nil }
        if photoLease?.url == url { photoLease?.transferToQueue(); photoLease = nil }
        for held in bulk.photoLeases where held.url == url { held.transferToQueue() }
        for held in bulk.videoLeases where held.url == url { held.transferToQueue() }
    }

    private func removeAcceptedSources(_ urls: Set<URL>) {
        for index in bulk.photos.indices.reversed() where urls.contains(bulk.photos[index].url) {
            bulk.photos.remove(at: index)
            bulk.photoLeases.remove(at: index)
        }
        for index in bulk.videos.indices.reversed() where urls.contains(bulk.videos[index].url) {
            bulk.videos.remove(at: index)
            bulk.videoLeases.remove(at: index)
        }
        if let photo, urls.contains(photo.url) { self.photo = nil }
        if let video, urls.contains(video.url) { self.video = nil }
        adoptedSources.removeAll { urls.contains($0.url) }
        if let adoptedURL, urls.contains(adoptedURL) { self.adoptedURL = nil }
        if sources.isEmpty { bulk = BulkStaging() }
    }

    /// Return queue-owned originals to UNQUEUED review. No enqueue or recipe
    /// mutation happens here, and no import lease may delete these originals.
    func adoptExistingJobs(_ jobs: [RenderJob]) async {
        guard !hasActiveRenders else {
            errorMessage = "These files are already developing."
            return
        }
        prepareSelection()
        resultJobIDs = []
        var seen: Set<String> = []
        var skipped: [String] = []
        for job in jobs {
            guard !Task.isCancelled else { cancelSelection(); return }
            guard job.hasRedevelopableSource, !job.isDiscardingImport,
                  job.originalOnly != true,
                  job.status == .completed || job.status == .failed else {
                skipped.append("\(job.sourceOriginalFilename ?? job.sourceURL.lastPathComponent): original unavailable or still developing.")
                continue
            }
            let source = DevelopSource(url: job.sourceURL,
                                       originalFilename: job.sourceOriginalFilename ?? job.sourceURL.lastPathComponent,
                                       isPhoto: job.isPhoto == true, iso: job.iso,
                                       capturedOffsetEV: job.sourceCapturedOffsetEV ?? job.pushPull?.meteredOffsetEV,
                                       cropZoom: job.photoCropZoom ?? 1)
            if seen.insert(source.id).inserted { adoptedSources.append(source) }
        }
        adoptedURL = adoptedSources.first?.url
        errorMessage = skipped.isEmpty ? nil : skipped.joined(separator: "\n")
    }

    /// Compatibility seam for older callers that hold only a photo URL.
    func adoptExistingPhoto(url: URL, originalFilename: String) async {
        prepareSelection()
        let token = generation
        isLoading = true
        do {
            let inspected = try await inspectPhoto(url, originalFilename)
            guard token == generation, !Task.isCancelled else { return }
            photo = inspected
            adoptedURL = url
        } catch {
            guard token == generation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "This photo can no longer be developed."
        }
        guard token == generation else { return }
        isLoading = false
    }

    func clearBulk() {
        // Fence any staging operation as well as releasing its held copies.
        cancelSelection()
    }

    func dismissBatch() { resultJobIDs = [] }

    func startOver() {
        cancelSelection()
        resultJobIDs = []
        errorMessage = nil
    }

    /// Accepted jobs are queue-owned and survive every selection cancellation.
    func cancelSelection() {
        generation = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        pendingTransfer = nil
        pendingPhotoTransfer = nil
        transferProgress?.cancel()
        transferProgress = nil
        lease = nil
        photoLease = nil
        bulk = BulkStaging()
        adoptedSources = []
        workflowOrder = []
        adoptedURL = nil
        photo = nil
        video = nil
        isLoading = false
    }

    func leaveDevelop() { cancelSelection(); errorMessage = nil }

    private func runSelection(token: UUID) async {
        guard let pending = pendingTransfer, pending.token == token else { return }
        do {
            let picked = try await pending.operation()
            guard token == generation, !Task.isCancelled else { return }
            let inspected = try await inspect(picked.url, picked.originalFilename)
            guard token == generation, !Task.isCancelled else { return }
            lease = picked.lease
            video = inspected
        } catch {
            guard token == generation else { return }
            errorMessage = "Choose an Apple Log 2 video that can be read on this device."
        }
        finish(token)
    }

    private func runPhotoSelection(token: UUID) async {
        guard let pending = pendingPhotoTransfer, pending.token == token else { return }
        do {
            let picked = try await pending.operation()
            let held = DevelopPhotoFileLease(picked.lease)
            guard token == generation, !Task.isCancelled else { return }
            let inspected = try await inspectPhoto(picked.url, picked.originalFilename)
            guard token == generation, !Task.isCancelled else { return }
            photoLease = held
            photo = inspected
        } catch {
            guard token == generation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Choose a raw photo that can be developed."
        }
        finish(token)
    }

    private func finish(_ token: UUID) {
        guard token == generation else { return }
        pendingTransfer = nil
        pendingPhotoTransfer = nil
        transferProgress = nil
        selectionTask = nil
        isLoading = false
    }

    func attachTransferProgress(_ progress: Progress?) { transferProgress = progress }

    func canRender(stock: FilmStockConfig?, queue: RenderQueueViewModel) -> Bool {
        guard let stock, !stock.stockId.isEmpty, !isLoading, !sources.isEmpty else { return false }
        return !isRenderActive(in: queue)
    }

    /// Imports have no camera meter. Never feed a file estimate into auto-pull.
    nonisolated static func resolvedPushPull(automatic: Bool, stops: PushPullStops) -> PushPullExposure {
        automatic ? .automatic(meteredOffsetEV: nil) : .manual(stops)
    }

    @discardableResult
    func render(stock: FilmStockConfig, iso: Float, gauge: PrintGauge,
                pushPull: PushPullExposure? = nil, queue: RenderQueueViewModel) -> UUID? {
        let result = submit(stock: stock, iso: iso, gauge: gauge, pushPull: pushPull, queue: queue)
        return result.queued > 0 ? resultJobIDs.first : nil
    }

    nonisolated static func grainSeed(for photo: ImportedPhoto) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in photo.url.lastPathComponent.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private func isRenderActive(in queue: RenderQueueViewModel) -> Bool {
        queue.jobs.contains {
            resultJobIDs.contains($0.id) && ($0.status == .pending || $0.status == .processing)
        }
    }

    private func clearSettledJobReference() {
        if !hasActiveRenders { resultJobIDs = [] }
    }
}
