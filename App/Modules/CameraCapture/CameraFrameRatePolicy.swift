import Foundation
import CoreMedia

/// Session-only capture frame-rate mode. Never persisted.
///
/// `.standard24` is the default and the cold-launch value. `.daylight60` is the
/// break-glass emergency exposure mode (fixed shutter `1/120`, 180°).
enum CameraFrameRate: Int, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case standard24 = 24
    case daylight60 = 60

    var id: Int { rawValue }
    var fps: Int { rawValue }

    /// 180° shutter denominator: 48 at 24 fps, 120 at 60 fps.
    var shutterDenominator: Int { rawValue * 2 }

    /// Fixed frame duration asserted on the capture device for this mode.
    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    /// The fixed 180° shutter for this mode.
    var filmShutterDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(shutterDenominator))
    }

    /// Recorder duration fallback for a sample that carries no duration.
    var fallbackVideoSampleDuration: CMTime { frameDuration }

    /// Maps a persisted/whole-number frame rate onto a mode, or nil if unknown.
    static func from(fps: Int) -> CameraFrameRate? {
        CameraFrameRate(rawValue: fps)
    }
}

/// Mirrors `CameraStabilizationPolicy.canChange`: a frame-rate change is only
/// allowed while no take is pending, active or draining.
enum CameraFrameRatePolicy {
    static func canChange(recording: Bool, starting: Bool, finishing: Bool) -> Bool {
        !recording && !starting && !finishing
    }
}
