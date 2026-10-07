import AVFoundation

/// AD-5: Exposure mode enum governing the exposure state machine.
enum ExposureMode: Equatable {
    /// Auto: camera meters both shutter and ISO. 24fps frame rate.
    case auto
    /// Shutter locked — ISO auto-adjusts to target EV.
    case shutterPriority(lockedShutter: Float64)
    /// ISO locked — shutter auto-adjusts, clamped per AD-4.
    case isoPriority(lockedISO: Float)
    /// Both locked — no auto-exposure. EV indicator shows over/under.
    case manual(shutter: Float64, iso: Float)
}

/// AD-4 + AD-5: Manages the exposure state, shutter clamping, and EV calculation.
@MainActor
final class ExposureManager {
    /// Shutter speed range per AD-4: 1/24 (min) to 1/100 (max).
    static let minShutter: Float64 = 1.0 / 24.0
    static let maxShutter: Float64 = 1.0 / 100.0
    /// Default shutter speed: 1/48 (180° shutter angle at 24fps).
    static let defaultShutter: Float64 = 1.0 / 48.0

    static let defaultISO: Float = 400
    static let defaultTargetEV: Float = 0.0

    var mode: ExposureMode = .auto
    var targetEV: Float = defaultTargetEV

    /// Returns the shutter duration as CMTime, clamped to AD-4 range.
    var clampedShutterDuration: CMTime {
        switch mode {
        case .auto:
            return Self.shutterDuration(for: Self.defaultShutter)
        case .shutterPriority(let lockedShutter):
            return Self.shutterDuration(for: Self.clamped(lockedShutter))
        case .isoPriority:
            return .invalid // determined by camera metering
        case .manual(let shutter, _):
            return Self.shutterDuration(for: Self.clamped(shutter))
        }
    }

    /// Returns the ISO value for the current mode, or nil if auto.
    var activeISO: Float? {
        switch mode {
        case .auto, .shutterPriority:
            return nil
        case .isoPriority(let lockedISO):
            return lockedISO
        case .manual(_, let iso):
            return iso
        }
    }

    /// Clamp a shutter speed to the AD-4 range [1/100, 1/24].
    static func clamped(_ value: Float64) -> Float64 {
        min(max(value, maxShutter), minShutter)
    }

    /// Convert a shutter speed (seconds) to CMTime.
    static func shutterDuration(for speed: Float64) -> CMTime {
        CMTime(seconds: speed, preferredTimescale: 1_000_000)
    }

    /// Toggle shutter lock: lock at current value, or unlock to auto.
    func toggleShutterLock(currentShutter: Float64) {
        switch mode {
        case .auto:
            mode = .shutterPriority(lockedShutter: Self.clamped(currentShutter))
        case .shutterPriority:
            mode = .auto
        case .isoPriority:
            mode = .manual(shutter: Self.clamped(currentShutter), iso: activeISO ?? Self.defaultISO)
        case .manual(let shutter, let iso):
            mode = .isoPriority(lockedISO: iso)
        }
    }

    /// Toggle ISO lock: lock at current value, or unlock to auto.
    func toggleISOLock(currentISO: Float) {
        switch mode {
        case .auto:
            mode = .isoPriority(lockedISO: currentISO)
        case .shutterPriority(let lockedShutter):
            mode = .manual(shutter: lockedShutter, iso: currentISO)
        case .isoPriority:
            mode = .auto
        case .manual(let shutter, _):
            mode = .shutterPriority(lockedShutter: shutter)
        }
    }

    /// Compute EV offset: 0 = correct exposure, negative = underexposed, positive = overexposed.
    @MainActor
    func computeEVOffset(meteredShutter: Float64, meteredISO: Float) -> Float {
        switch mode {
        case .auto:
            return targetEV
        case .shutterPriority(let lockedShutter):
            let ratio = Float(meteredISO) / (activeISO ?? meteredISO)
            return targetEV + log2(ratio)
        case .isoPriority(let lockedISO):
            let ratio = Float(meteredShutter) / Float(Self.clamped(meteredShutter))
            return targetEV + log2(ratio)
        case .manual(let shutter, let iso):
            let shutterRatio = Float(shutter) / Float(meteredShutter)
            let isoRatio = Float(iso) / Float(meteredISO)
            return targetEV + log2(shutterRatio) + log2(isoRatio)
        }
    }
}