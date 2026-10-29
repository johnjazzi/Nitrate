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
}

enum PhotoExposurePolicyError: Error, Equatable {
    case nonFiniteInput
    case invalidRange
    case valueOutOfRange
    case negativeCorrectionLimit
}

enum PhotoExposurePolicy {
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
                       request: PhotoExposureRequest) throws -> PhotoExposureDecision {
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
        if !snapshot.isoLocked && !snapshot.shutterLocked {
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
