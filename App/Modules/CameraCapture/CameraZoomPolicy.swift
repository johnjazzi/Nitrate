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

enum CameraZoomDirection: Sendable { case out, `in` }

enum CameraZoomPolicy {
    static let defaultDisplayCeiling = 5.0
    static let telephotoDisplayCeiling = 16.0
    static let rampRate: Float = 0.25

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
