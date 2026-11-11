import Foundation

/// A proposed adjustment from the Photo metering controller.
struct PhotoExposureRequest: Equatable, Sendable {
    let ev: Float
    /// Unbiased measured EV, in stops above the neutral target.
    let measuredEV: Float
    let maxCorrectionEV: Float
}

struct PhotoExposureDecision: Equatable, Sendable {
    let iso: Float?
    let durationSeconds: Double?
    let meteringOffset: Float
    let targetLimited: Bool
    let isSettling: Bool
    let usesAutoExposure: Bool

    /// Reaching a hardware limit can end settling while still requiring the
    /// final clamped command. Never use `isSettling` as write eligibility.
    func command(for snapshot: PhotoExposureSnapshot) -> PhotoExposureCommand? {
        guard !usesAutoExposure, iso != nil || durationSeconds != nil else { return nil }
        let command = PhotoExposureCommand(iso: iso ?? snapshot.iso,
            durationSeconds: durationSeconds ?? snapshot.durationSeconds)
        guard PhotoExposureCadence.needsWrite(iso: command.iso, duration: command.durationSeconds,
            actualISO: snapshot.iso, actualDuration: snapshot.durationSeconds) else { return nil }
        return command
    }
}

struct PhotoExposureCommand: Equatable, Sendable {
    let iso: Float
    let durationSeconds: Double
}

/// The metered exposure the operator was looking at, and the aperture and
/// compensation it was metered under. The controller records it before its
/// first custom write, because the device's own metering produced it.
struct PhotoApertureBaseline: Equatable, Sendable {
    let iso: Float
    let aperture: Float
    let ev: Float
}

struct PhotoApertureResolution: Equatable, Sendable {
    let iso: Float
    /// The compensation this ISO actually delivers, in EV from neutral. Equals
    /// the requested EV unless the ISO range clipped the request.
    let achievedEV: Float
    let targetLimited: Bool
}

enum PhotoApertureExposurePolicy {
    /// The ISO that puts a held aperture back on the operator's EV target.
    ///
    /// Exposure is `ISO * t / N²`, so moving the iris from `baseline.aperture`
    /// to `aperture` changes the light by `(aperture / baseline.aperture)²` and
    /// is answered in gain; a change of target scales it by
    /// `2^(ev - baseline.ev)`. Both terms are measured from the *baseline*, not
    /// from the ISO currently installed: deriving the next value from the value
    /// a previous move already corrected compounds every gesture.
    ///
    /// When the request lands outside the format's ISO range the resolution is
    /// clamped and flagged `targetLimited`, and `achievedEV` reports the
    /// compensation that clamp really delivers, so the UI can say the target is
    /// unreachable instead of showing a meter parked several stops off it.
    static func resolveISO(baseline: PhotoApertureBaseline, aperture: Float,
                           ev: Float, isoRange: ClosedRange<Float>) -> PhotoApertureResolution? {
        guard baseline.iso.isFinite, baseline.iso > 0,
              baseline.aperture.isFinite, baseline.aperture > 0,
              aperture.isFinite, aperture > 0,
              ev.isFinite, baseline.ev.isFinite,
              isoRange.lowerBound.isFinite, isoRange.upperBound.isFinite,
              isoRange.lowerBound > 0, isoRange.upperBound >= isoRange.lowerBound else { return nil }
        let iris = Double(aperture) / Double(baseline.aperture)
        let proposed = Double(baseline.iso) * iris * iris * pow(2.0, Double(ev - baseline.ev))
        guard proposed.isFinite, proposed > 0 else { return nil }
        let value = min(max(proposed, Double(isoRange.lowerBound)), Double(isoRange.upperBound))
        // 2^achievedEV / 2^requestedEV = value / proposed, so the shortfall is
        // one log2 away from the requested target.
        let achieved = ev + Float(log2(value / proposed))
        return PhotoApertureResolution(iso: Float(value),
                                       achievedEV: achieved,
                                       targetLimited: abs(value - proposed) > proposed * 0.0001)
    }
}

enum PhotoExposurePolicyError: Error, Equatable {
    case nonFiniteInput
    case invalidRange
    case valueOutOfRange
    case negativeCorrectionLimit
}

enum PhotoExposurePolicy {
    static func usesNativeAutoExposure(isoLocked: Bool, shutterLocked: Bool, apertureHeld: Bool) -> Bool {
        !isoLocked && !shutterLocked && !apertureHeld
    }

    static func shouldSuspendPreview(durationSeconds: Double) -> Bool {
        durationSeconds.isFinite && durationSeconds > 1.0 / 8.0
    }

    static func captureAvailable(started: Bool, stopped: Bool, capturing: Bool) -> Bool {
        started && !stopped && !capturing
    }
    static let settlingToleranceEV: Float = 0.05
    /// Inside this error the correction keeps its small step so the loop damps
    /// instead of hunting; beyond it the step may grow by
    /// `farCorrectionMultiplier`, so a large metering error does not crawl to
    /// the target one quarter stop at a time.
    static let nearTargetEV: Float = 0.5
    static let farCorrectionMultiplier: Float = 4

    static func decide(snapshot: PhotoExposureSnapshot,
                       request: PhotoExposureRequest,
                       apertureHeld: Bool = false) throws -> PhotoExposureDecision {
        guard request.ev.isFinite, request.measuredEV.isFinite,
              request.maxCorrectionEV.isFinite,
              snapshot.isoRange.lowerBound.isFinite, snapshot.isoRange.upperBound.isFinite,
              snapshot.shutterRange.lowerBound.isFinite, snapshot.shutterRange.upperBound.isFinite,
              snapshot.iso.isFinite, snapshot.durationSeconds.isFinite else {
            throw PhotoExposurePolicyError.nonFiniteInput
        }
        guard request.maxCorrectionEV >= 0 else { throw PhotoExposurePolicyError.negativeCorrectionLimit }
        guard snapshot.isoRange.lowerBound > 0,
              snapshot.isoRange.upperBound >= snapshot.isoRange.lowerBound,
              snapshot.shutterRange.lowerBound > 0,
              snapshot.shutterRange.upperBound >= snapshot.shutterRange.lowerBound else {
            throw PhotoExposurePolicyError.invalidRange
        }
        guard snapshot.isoRange.contains(snapshot.iso),
              snapshot.shutterRange.contains(snapshot.durationSeconds) else {
            throw PhotoExposurePolicyError.valueOutOfRange
        }

        let errorEV = request.ev - request.measuredEV
        let meteringOffset = -errorEV
        let settling = abs(errorEV) > settlingToleranceEV
        if usesNativeAutoExposure(isoLocked: snapshot.isoLocked, shutterLocked: snapshot.shutterLocked,
                                  apertureHeld: apertureHeld) {
            return .init(iso: nil, durationSeconds: nil, meteringOffset: meteringOffset,
                         targetLimited: false, isSettling: settling, usesAutoExposure: true)
        }
        guard !(snapshot.isoLocked && snapshot.shutterLocked) else {
            return .init(iso: nil, durationSeconds: nil, meteringOffset: meteringOffset,
                         targetLimited: false, isSettling: false, usesAutoExposure: false)
        }

        let limit = abs(errorEV) <= nearTargetEV
            ? request.maxCorrectionEV
            : request.maxCorrectionEV * farCorrectionMultiplier
        let correction = min(max(errorEV, -limit), limit)
        if abs(errorEV) <= settlingToleranceEV {
            return .init(iso: nil, durationSeconds: nil, meteringOffset: meteringOffset,
                         targetLimited: false, isSettling: false, usesAutoExposure: false)
        }
        let factor = pow(2.0, Double(correction))
        // Explicit aperture with neither leg held retains the existing ISO-only
        // policy. It reports ISO saturation rather than silently claiming AE.
        if !snapshot.isoLocked {
            let proposed = Double(snapshot.iso) * factor
            let value = min(max(proposed, Double(snapshot.isoRange.lowerBound)), Double(snapshot.isoRange.upperBound))
            let limited = value != proposed
            return .init(iso: Float(value), durationSeconds: nil, meteringOffset: meteringOffset,
                         targetLimited: limited, isSettling: settling && !limited,
                         usesAutoExposure: false)
        }
        // A pinned ISO leaves the shutter as the only lever the metering has, so
        // the shutter floats to reach the compensation — the same way the
        // device's own auto exposure shortens the shutter as the scene brightens.
        // An operator who wants the shutter held locks the shutter itself, which
        // is a separate control (`isShutterPriority`/`shutterLocked`).
        let proposed = snapshot.durationSeconds * factor
        let value = min(max(proposed, snapshot.shutterRange.lowerBound), snapshot.shutterRange.upperBound)
        let floated = PhotoShutterFloatPolicy.clampedFloat(value, current: snapshot.durationSeconds)
        let limited = floated != proposed
        return .init(iso: nil, durationSeconds: floated, meteringOffset: meteringOffset,
                     targetLimited: limited, isSettling: settling && !limited,
                     usesAutoExposure: false)
    }
}
