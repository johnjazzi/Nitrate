import Foundation

/// Private local evidence captured from the delivered movie, never from Photos.
struct RenderReceipt: Codable, Equatable, Sendable {
    /// The source file's own properties, read once at delivery while the local
    /// original still exists. Nil for legacy receipts and cleaned-up media.
    struct Original: Codable, Equatable, Sendable {
        var codec: String? = nil
        var pixelWidth: Int? = nil
        var pixelHeight: Int? = nil
        var framesPerSecond: Double? = nil
        var fileSizeBytes: Int64? = nil
    }

    var recordedAt: Date = Date()
    var durationSeconds: Double? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var framesPerSecond: Double? = nil
    var codec: String? = nil
    var fileSizeBytes: Int64? = nil
    var renderDurationSeconds: Double? = nil
    var thumbnailJPEG: Data? = nil
    var metadata: [String: String] = [:]
    var appVersion: String? = nil
    var appBuild: String? = nil
    var original: Original? = nil

    private enum CodingKeys: String, CodingKey {
        case recordedAt, durationSeconds, pixelWidth, pixelHeight, framesPerSecond, codec
        case fileSizeBytes, renderDurationSeconds, thumbnailJPEG, metadata, appVersion, appBuild
        case original
    }

    init(recordedAt: Date = Date(), durationSeconds: Double? = nil,
         pixelWidth: Int? = nil, pixelHeight: Int? = nil, framesPerSecond: Double? = nil,
         codec: String? = nil, fileSizeBytes: Int64? = nil, renderDurationSeconds: Double? = nil,
         thumbnailJPEG: Data? = nil, metadata: [String: String] = [:],
         appVersion: String? = nil, appBuild: String? = nil, original: Original? = nil) {
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.fileSizeBytes = fileSizeBytes
        self.renderDurationSeconds = renderDurationSeconds
        self.thumbnailJPEG = thumbnailJPEG
        self.metadata = metadata
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.original = original
    }
}
