import Foundation
import CoreMedia

/// Session-only capture frame-rate mode. Never persisted.
///
/// `.standard24` is the default and the cold-launch value. `.daylight60` is the
/// break-glass emergency exposure mode (fixed shutter `1/120`, 180°).
/// `.high120` is the manual-mode high-rate capture: a real 120 fps capture, not
/// a 120th shutter at 60 fps.
enum CameraFrameRate: Int, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case standard24 = 24
    case daylight60 = 60
    case high120 = 120

    var id: Int { rawValue }
    var fps: Int { rawValue }

    /// The default mode. Every session starts and resets here.
    var isStandard: Bool { self == .standard24 }

    /// 180° shutter denominator: 48 at 24 fps, 120 at 60 fps, 240 at 120 fps.
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

/// The exposure a shooting mode's idle camera graph holds while the operator is
/// not overriding it. The value type exists so the contract is decided once, in
/// one place, instead of being re-derived by every caller.
struct IdleExposureContract: Equatable, Sendable {
    let durationSeconds: Double?
    /// Nil leaves ISO metering automatically; a value pins the operator's ISO.
    let lockedISO: Float?
    let exposureBias: Float
}

/// Shared idle retains explicit operator holds only. The recording start path
/// separately owns its 180° shutter; changing UI modes never installs it.
enum VideoExposureContract {
    static func idle(frameRate: CameraFrameRate, isManualExposure: Bool,
                     manualISO: Float, bias: Float, heldDuration: Double? = nil) -> IdleExposureContract {
        IdleExposureContract(durationSeconds: heldDuration,
                             lockedISO: isManualExposure ? manualISO : nil,
                             exposureBias: bias)
    }
}

/// Mirrors `CameraStabilizationPolicy.canChange`: a frame-rate change is only
/// allowed while no take is pending, active or draining.
enum CameraFrameRatePolicy {
    /// Synchronous transaction seam shared by device configuration and tests.
    static func applyTransition(format: () throws -> Void, exposure: () throws -> Void,
                                rollback: () -> Void) throws {
        do {
            try format()
            try exposure()
        } catch {
            rollback()
            throw error
        }
    }

    static func canChange(recording: Bool, starting: Bool, finishing: Bool) -> Bool {
        !recording && !starting && !finishing
    }

    /// The modes a device can capture, ascending, always including the
    /// `.standard24` baseline. Never advertises a rate the device cannot deliver,
    /// so a control is disabled instead of a take failing on a silent downgrade.
    static func availableModes(
        _ isEligible: (CameraFrameRate) -> Bool,
        highFrameRateEnabled: Bool = HighFrameRateFeature.isAvailableInThisBuild()
    ) -> [CameraFrameRate] {
        [.standard24] + [.daylight60, .high120].filter {
            HighFrameRateFeature.allows(fps: $0.fps, available: highFrameRateEnabled)
                && isEligible($0)
        }
    }

    /// How a foreground-session boundary resolves the capture frame rate.
    ///
    /// The mode is session-only, so the boundary resets it to `.standard24`. When
    /// a take is still pending or draining, the device reset has to wait for the
    /// take to finish; otherwise the recorder would end on a different rate than
    /// it started. Deferring loses nothing because the enqueued job keeps the
    /// policy captured at take start.
    static func resetAction(recording: Bool, starting: Bool, finishing: Bool) -> CameraFrameRateResetAction {
        canChange(recording: recording, starting: starting, finishing: finishing)
            ? .resetImmediately
            : .deferUntilTakeFinishes
    }
}

/// The boundary reset decision. See `CameraFrameRatePolicy.resetAction`.
enum CameraFrameRateResetAction: Equatable {
    /// No take is pending, active or draining: reset at once.
    case resetImmediately
    /// A take is pending or draining: reset once it finishes.
    case deferUntilTakeFinishes
}

/// Associates the capture policy taken at take start with the completed source
/// URL. The screen and the queue read the policy from here, never from the live
/// mode, so a session-boundary reset cannot mislabel a queued job.
///
/// Bounded so a long session cannot grow it without limit; the most recent takes
/// are kept. A failed or cancelled take is simply never recorded, so it cannot
/// corrupt an earlier take's mapping.
struct DaylightCapturePolicyLedger: Equatable {
    private(set) var policies: [URL: RenderCapturePolicy] = [:]
    private var order: [URL] = []
    private let limit: Int

    init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    /// Record the mode captured when a take started, before the screen observes
    /// the completed URL.
    mutating func record(sourceURL: URL, mode: CameraFrameRate, sourceProfile: CameraSourceProfile = .appleLog2) {
        guard let policy = RenderCapturePolicy(mode.fps, sourceProfile: sourceProfile) else { return }
        let key = sourceURL.standardizedFileURL
        policies[key] = policy
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            policies[order.removeFirst()] = nil
        }
    }

    /// The policy for a completed take, or nil if it is unknown/legacy.
    func policy(for sourceURL: URL) -> RenderCapturePolicy? {
        policies[sourceURL.standardizedFileURL]
    }

    mutating func clear() {
        policies.removeAll()
        order.removeAll()
    }
}
