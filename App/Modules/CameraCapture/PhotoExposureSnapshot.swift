import Foundation

/// Values measured from, or explicitly pinned on, the active Photo configuration.
/// This is a control snapshot, not proof of a captured DNG's exposure.
struct PhotoExposureSnapshot: Equatable, Sendable {
    let iso: Float
    let durationSeconds: Double
    let isoRange: ClosedRange<Float>
    let shutterRange: ClosedRange<Double>
    let isoLocked: Bool
    let shutterLocked: Bool
    let ev: Float
    /// Neutral scene offset, in EV: raw device offset + installed device bias.
    /// Compare with requested EV regardless of the ISO/shutter hold combination.
    let meteringOffset: Float
    let isSettling: Bool
    let canCapture: Bool
    let targetLimited: Bool
    /// Native unrotated RAW dimensions; zero only before capability is known.
    var photoWidth: Int = 0
    var photoHeight: Int = 0
    /// A new controller/device invalidates old pending UI intent even if its
    /// format has exactly the same ranges. Nil preserves legacy test callers.
    var sourceID: UUID? = nil

    static func neutralMeteringOffset(rawOffset: Float, installedBias: Float) -> Float {
        rawOffset + installedBias
    }
}
