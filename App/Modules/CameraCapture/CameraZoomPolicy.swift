import Foundation

struct CameraZoomSnapshot: Equatable, Sendable {
    let cameraRevision: UInt64
    let displayFactor: Double
    let minimumDisplayFactor: Double
    let maximumDisplayFactor: Double
    let isRamping: Bool
    let isPerLens: Bool
    /// The active device's display multiplier: the session publishes
    /// `displayFactor == device.videoZoomFactor * displayMultiplier`. Converting
    /// between a display factor and a lens-native focal length needs the real
    /// value, because one global 24 mm reference is not exact (the ultrawide's
    /// own 0.5x is 13 mm, not 12 mm). Defaults to 1, which is both the per-lens
    /// (iOS 17) value and a valid value for any construction that predates it.
    var displayMultiplier: Double = 1

    var isAvailable: Bool { maximumDisplayFactor >= minimumDisplayFactor }
    func accepting(_ incoming: CameraZoomSnapshot) -> CameraZoomSnapshot {
        incoming.cameraRevision >= cameraRevision ? incoming : self
    }
}

enum CameraZoomDirection: Sendable, Equatable { case out, `in` }

enum CameraZoomPolicy {
    static let defaultDisplayCeiling = 5.0
    static let telephotoDisplayCeiling = 16.0
    /// Convert the main camera's 150 mm limit into its published display scale.
    /// The native crop is 150 / 24; the device's display multiplier is separate.
    static func mainWideDisplayCeiling(multiplier: Double) -> Double {
        multiplier * (150.0 / 24.0)
    }
    static let rampRate: Float = 0.25
    /// Step cadence for an app-driven slow zoom. 60 Hz keeps the preview
    /// following the hand the way the removed hardware ramp did.
    static let rampTickInterval: TimeInterval = 1.0 / 60.0
    /// Slow-zoom snapshot cadence. The label and ruler do not need a per-frame
    /// update, and every publish hops to the main actor.
    static let rampPublishInterval: TimeInterval = 0.1

    struct Bounds: Equatable, Sendable {
        let multiplier: Double
        let minimumDevice: Double
        let maximumDevice: Double
        var minimumDisplay: Double { minimumDevice * multiplier }
        var maximumDisplay: Double { maximumDevice * multiplier }
        func target(_ display: Double) -> Double? {
            guard display.isFinite, display > 0 else { return nil }
            return min(max(display / multiplier, minimumDevice), maximumDevice)
        }
    }

    static func bounds(multiplier: Double, effectiveMinimum: Double,
                       effectiveMaximum: Double, formatMaximum: Double,
                       displayCeiling: Double = defaultDisplayCeiling) -> Bounds? {
        guard [multiplier, effectiveMinimum, effectiveMaximum, formatMaximum, displayCeiling]
            .allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        let lower = max(1, effectiveMinimum)
        let upper = min(effectiveMaximum, formatMaximum, displayCeiling / multiplier)
        guard lower <= upper else { return nil }
        return Bounds(multiplier: multiplier, minimumDevice: lower, maximumDevice: upper)
    }

    static func accepts(commandRevision: UInt64, cameraRevision: UInt64) -> Bool {
        commandRevision == cameraRevision
    }

    /// Device zoom factor for an app-driven ramp `elapsed` seconds after it
    /// started, at `rate` stops per second toward `direction`.
    ///
    /// Elapsed time is measured by the caller from a monotonic clock, not
    /// counted in ticks: a late or coalesced tick then catches up on the next
    /// step instead of slowing the ramp down. The result is clamped to the
    /// supplied device window, so a late tick lands exactly on an endpoint
    /// rather than overshooting it; an absurd elapsed value saturates to the
    /// endpoint too. Returns nil for unusable input so a bad command can never
    /// move the lens.
    static func rampFactor(initial: Double, rate: Double, elapsed: TimeInterval,
                           direction: CameraZoomDirection,
                           minimum: Double, maximum: Double) -> Double? {
        guard initial.isFinite, initial > 0,
              rate.isFinite, rate > 0,
              elapsed.isFinite, elapsed >= 0,
              minimum.isFinite, minimum > 0,
              maximum.isFinite, minimum <= maximum else { return nil }
        let octaves = rate * elapsed
        let factor = direction == .in
            ? initial * pow(2, octaves)
            : initial * pow(2, -octaves)
        // `pow` saturates to infinity/zero for extreme elapsed values; clamping
        // turns either one into the endpoint instead of failing the ramp.
        return min(max(factor, minimum), maximum)
    }
}

struct CameraZoomRampLifecycle {
    private(set) var cameraRevision: UInt64 = 0
    private(set) var isRamping = false
    mutating func cameraChanged() { cameraRevision &+= 1; isRamping = false }
    mutating func begin(revision: UInt64) -> Bool {
        guard CameraZoomPolicy.accepts(commandRevision: revision, cameraRevision: cameraRevision) else { return false }
        isRamping = true
        return true
    }
    mutating func end(revision: UInt64) -> Bool {
        guard CameraZoomPolicy.accepts(commandRevision: revision, cameraRevision: cameraRevision), isRamping else {
            return false
        }
        isRamping = false
        return true
    }
}
