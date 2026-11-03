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
    /// 24, 60 or 120.
    let frameRate: Int
    let grainPairing: GrainPairing
    /// 180° fixed shutter denominator: 48, 120 or 240.
    let shutterDenominator: Int

    private enum CodingKeys: String, CodingKey {
        case frameRate, grainPairing, shutterDenominator
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rate = try values.decode(Int.self, forKey: .frameRate)
        guard let policy = Self(rate),
              try values.decode(GrainPairing.self, forKey: .grainPairing) == policy.grainPairing,
              try values.decode(Int.self, forKey: .shutterDenominator) == policy.shutterDenominator else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Capture policy must be 24fps/1⁄48/per-frame, or 60fps/1⁄120 or 120fps/1⁄240 with paired grain."))
        }
        self = policy
    }

    /// Nil unless `frameRate` is 24, 60 or 120. Derives the pairing and shutter
    /// from the rate so the three values cannot disagree. `nil` in a job means
    /// legacy behaviour: 24 fps, per-frame grain, `1/48` shutter metadata.
    ///
    /// Above 24 fps the 180° shutter keeps the same half-rate paired grain
    /// semantics: a 120 fps take gets 60 grain realisations, exactly as a 60 fps
    /// take gets 30, so grain never becomes per-frame noise at a high rate.
    init?(_ frameRate: Int) {
        switch frameRate {
        case 24:
            self.frameRate = 24
            self.grainPairing = .perFrame
            self.shutterDenominator = 48
        case 60:
            self.frameRate = 60
            self.grainPairing = .pairedAtHalfRate
            self.shutterDenominator = 120
        case 120:
            self.frameRate = 120
            self.grainPairing = .pairedAtHalfRate
            self.shutterDenominator = 240
        default:
            return nil
        }
    }
}

/// The slate a take belongs to: reel, scene and take number.
///
/// Nitrate records one take per recording today, so the shipped value is always
/// 1/1/1. It lives here, with the capture policy, because the movie and still
/// metadata writers both read it and neither compiles the render queue.
struct RenderSlate: Codable, Equatable, Sendable {
    var reel: Int
    var scene: Int
    var take: Int

    /// The only slate the app writes: the first take of the first scene on reel
    /// one. Stated as fact in the delivered file, never inferred by a reader.
    static let first = RenderSlate(reel: 1, scene: 1, take: 1)
}
