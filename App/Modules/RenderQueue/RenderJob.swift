import AVFoundation

/// AD-7: Codable job model for the render queue.
/// Persisted to disk to survive app backgrounding.
struct RenderJob: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    /// Empty for a capture that has not been assigned a stock yet
    /// (`status == .awaitingStock`) and for an original-only rescue entry.
    var stockId: String
    var iso: Float
    /// Print gauge for this render. Optional so older queue JSON stays readable;
    /// nil means the stock's own gauge (or the neutral 35mm reference).
    var printGauge: PrintGauge?
    /// Immutable enqueue-time preferences; nil preserves legacy delivery behavior.
    var deliveryPreferences: RenderDeliveryPreferences?
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
    /// True for a kept original queued for verbatim Photos delivery. Such a job
    /// is never rendered, even after a relaunch. Optional so older queue JSON
    /// (and every ordinary render job) stays readable as `nil`.
    var originalOnly: Bool? = nil
    /// Why a kept original was retained (a validation failure), kept for the
    /// queue row. Never used to decide rendering.
    var retainedReason: String? = nil

    init(sourceURL: URL, stockId: String, iso: Float, printGauge: PrintGauge? = nil,
         trimStart: CMTime? = nil, trimEnd: CMTime? = nil,
         sessionId: String? = nil, createdAt: Date = Date(),
         deliveryPreferences: RenderDeliveryPreferences? = nil) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.stockId = stockId
        self.iso = iso
        self.printGauge = printGauge
        self.deliveryPreferences = deliveryPreferences
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
