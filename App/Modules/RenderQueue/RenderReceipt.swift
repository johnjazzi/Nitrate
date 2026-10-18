import Foundation

/// Private local evidence captured from the delivered movie, never from Photos.
struct RenderReceipt: Codable, Equatable, Sendable {
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
}
