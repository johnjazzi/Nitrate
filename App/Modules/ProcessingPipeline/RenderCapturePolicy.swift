import Foundation

/// The per-take capture policy, snapshotted at enqueue and carried in the job
/// JSON so a queued job renders identically after a relaunch without reading
/// live UI.
///
/// It lives in the processing-pipeline module because the renderer and the movie
/// metadata both need it, and neither is compiled alongside the render queue in
/// every target. A constrained value: the frame rate fixes the grain pairing and
/// the fixed 180° shutter together, so an invalid fps/shutter/grain combination
/// cannot be constructed.
struct RenderCapturePolicy: Codable, Equatable, Sendable {
    /// 24 or 60.
    var frameRate: Int
    var grainPairing: GrainPairing
    /// 180° fixed shutter denominator: 48 or 120.
    var shutterDenominator: Int

    /// Nil unless `frameRate` is 24 or 60. Derives the pairing and shutter from
    /// the rate so the three values cannot disagree. `nil` in a job means legacy
    /// behaviour: 24 fps, per-frame grain, `1/48` shutter metadata.
    init?(_ frameRate: Int) {
        self.frameRate = frameRate
        self.grainPairing = .perFrame
        self.shutterDenominator = 48
    }
}
