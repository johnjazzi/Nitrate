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
    let frameRate: Int
    let grainPairing: GrainPairing
    /// 180° fixed shutter denominator: 48 or 120.
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
                debugDescription: "Capture policy must be 24fps/1⁄48/per-frame or 60fps/1⁄120/paired grain."))
        }
        self = policy
    }

    /// Nil unless `frameRate` is 24 or 60. Derives the pairing and shutter from
    /// the rate so the three values cannot disagree. `nil` in a job means legacy
    /// behaviour: 24 fps, per-frame grain, `1/48` shutter metadata.
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
        default:
            return nil
        }
    }
}
