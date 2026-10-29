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
    let meteringOffset: Float
    let isSettling: Bool
    let canCapture: Bool
    let targetLimited: Bool
    /// Native unrotated RAW dimensions; zero only before capability is known.
    var photoWidth: Int = 0
    var photoHeight: Int = 0
}
