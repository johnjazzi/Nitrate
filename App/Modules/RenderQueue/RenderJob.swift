import AVFoundation

/// AD-7: Codable job model for the render queue.
/// Persisted to disk to survive app backgrounding.
struct RenderJob: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let stockId: String
    let iso: Float
    let trimStartSeconds: Double?
    let trimEndSeconds: Double?
    let createdAt: Date

    var status: JobStatus = .pending
    var outputURL: URL?
    var errorMessage: String?

    init(sourceURL: URL, stockId: String, iso: Float,
         trimStart: CMTime? = nil, trimEnd: CMTime? = nil) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.stockId = stockId
        self.iso = iso
        self.trimStartSeconds = trimStart.map { $0.seconds }
        self.trimEndSeconds = trimEnd.map { $0.seconds }
        self.createdAt = Date()
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
    }
}