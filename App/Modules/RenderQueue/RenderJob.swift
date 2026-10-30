import AVFoundation
import Foundation

/// AD-7: Codable job model for the render queue.
/// Persisted to disk to survive app backgrounding.
struct RenderJob: Codable, Identifiable, Equatable {
    let id: UUID
    /// Re-rooted onto the current app container when a persisted queue is read:
    /// iOS assigns a new container directory on install/update.
    var sourceURL: URL
    /// Empty for a capture that has not been assigned a stock yet
    /// (`status == .awaitingStock`) and for an original-only rescue entry.
    var stockId: String
    var iso: Float
    /// Print gauge for this render. Optional so older queue JSON stays readable;
    /// nil means the stock's own gauge (or the neutral 35mm reference).
    var printGauge: PrintGauge?
    /// Immutable enqueue-time preferences; nil preserves legacy delivery behavior.
    var deliveryPreferences: RenderDeliveryPreferences?
    /// Nil preserves legacy camera jobs. Imported assets never expose playback
    /// or export another copy of their original into Photos.
    var isImportedVideo: Bool? = nil
    /// Photo jobs share queue persistence/retry but retain their DNG and JPEG.
    /// Optional fields keep every pre-Photo queue readable as a Video queue.
    var isPhoto: Bool? = nil
    var photoCropZoom: Double? = nil
    var photoGrainSeed: UInt32? = nil
    var retainedOutputURL: URL? {
        guard let outputURL, outputURL.isFileURL,
              let values = try? outputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return outputURL
    }
    /// The retained DNG is still on disk, so a Photo job can be developed again.
    var hasRedevelopableOriginal: Bool {
        guard isPhoto == true, sourceURL.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
    }

    /// Durable removal intent. Recovery and Retry clean files without rendering.
    var discardImportedMedia: Bool? = nil
    var isDiscardingImport: Bool { isImportedVideo == true && discardImportedMedia == true }
    var permitsLocalMedia: Bool { isImportedVideo != true }
    /// Media-aware original delivery: a Photo job honours the independent RAW
    /// switch, a video honours `saveOriginalLog`. Imported video never exports.
    var shouldSaveOriginal: Bool {
        guard isImportedVideo != true else { return false }
        if isPhoto == true { return deliveryPreferences?.saveOriginalRAWToPhotos == true }
        return deliveryPreferences?.saveOriginalLog == true
    }
    let trimStartSeconds: Double?
    let trimEndSeconds: Double?
    let createdAt: Date
    var sessionId: String

    var status: JobStatus = .pending
    var outputURL: URL?
    var errorMessage: String?
    /// Delivery outcomes are optional so older queue JSON remains readable.
    var sourceSavedToPhotos: Bool? = nil
    var outputSavedToPhotos: Bool? = nil
    /// Local export evidence; absent for legacy history, never inferred later.
    var receipt: RenderReceipt? = nil
    /// True only after all owned movie references are removed or already missing.
    var mediaCleanupCompleted: Bool? = nil
    var cleanupWarning: String? = nil
    /// True for a kept original queued for verbatim Photos delivery. Such a job
    /// is never rendered, even after a relaunch. Optional so older queue JSON
    /// (and every ordinary render job) stays readable as `nil`.
    var originalOnly: Bool? = nil
    /// Why a kept original was retained (a validation failure), kept for the
    /// queue row. Never used to decide rendering.
    var retainedReason: String? = nil
    /// Capture policy snapshotted at enqueue. Immutable value; the renderer and
    /// metadata read this, never live UI. `nil` preserves legacy behaviour:
    /// 24 fps, per-frame grain, `1/48` shutter metadata.
    var capturePolicy: RenderCapturePolicy? = nil

    init(sourceURL: URL, stockId: String, iso: Float, printGauge: PrintGauge? = nil,
         trimStart: CMTime? = nil, trimEnd: CMTime? = nil,
         sessionId: String? = nil, createdAt: Date = Date(),
         deliveryPreferences: RenderDeliveryPreferences? = nil,
         capturePolicy: RenderCapturePolicy? = nil) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.stockId = stockId
        self.iso = iso
        self.printGauge = printGauge
        self.deliveryPreferences = deliveryPreferences
        self.capturePolicy = capturePolicy
        self.trimStartSeconds = trimStart.map { $0.seconds }
        self.trimEndSeconds = trimEnd.map { $0.seconds }
        self.createdAt = createdAt
        self.sessionId = sessionId ?? RenderJob.currentSessionId
        self.sourceSavedToPhotos = nil
        self.outputSavedToPhotos = nil
    }

    /// A take captured before a stock was chosen. It must not render until a
    /// stock is assigned, and it is durable so Done/swipe/relaunch cannot strand
    /// the capture.
    init(awaitingStockSourceURL: URL, sessionId: String? = nil, createdAt: Date = Date()) {
        self.init(sourceURL: awaitingStockSourceURL, stockId: "", iso: 0,
                  sessionId: sessionId, createdAt: createdAt)
        self.status = .awaitingStock
    }

    /// A kept original that failed validation: delivered to Photos verbatim and
    /// never rendered.
    init(originalOnlySourceURL: URL, reason: String, sessionId: String? = nil,
         createdAt: Date = Date()) {
        self.init(sourceURL: originalOnlySourceURL, stockId: "", iso: 0,
                  sessionId: sessionId, createdAt: createdAt)
        self.originalOnly = true
        self.retainedReason = reason
    }

    var trimStart: CMTime? {
        trimStartSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) }
    }

    var trimEnd: CMTime? {
        trimEndSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) }
    }

    var trimRange: CMTimeRange? {
        guard let start = trimStart, let end = trimEnd else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    enum JobStatus: String, Codable {
        case pending
        case processing
        case completed
        case failed
        /// Captured with no stock selected; discoverable and resumable, never
        /// rendered until a stock is assigned.
        case awaitingStock
    }

    /// Stable for this process, independent of persisted queue state and view lifecycle.
    static let currentSessionId = UUID().uuidString
}
