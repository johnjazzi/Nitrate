import Foundation

/// The one rule left on an auto-floating Photo shutter: how slow it may go.
///
/// Pinning the ISO no longer pins the shutter. The operator who holds the ISO is
/// holding *sensitivity*; the shutter is then the metering's only lever and it
/// floats to reach the compensation, exactly as the device's own auto exposure
/// would. A held shutter is a separate, explicit choice on the shutter rail.
enum PhotoShutterFloatPolicy {
    /// The longest exposure a float may choose: 1/16s. Anything slower is a
    /// deliberate manual selection (`shutterRange` still offers it), never
    /// something auto-exposure may pick on its own.
    static let floorSeconds: Double = 1.0 / 16.0

    /// Clamp a floated speed to the 1/16s floor without shortening an exposure
    /// the operator already set slower than it (a manual 1/8s stays 1/8s).
    static func clampedFloat(_ seconds: Double, current: Double) -> Double {
        let floor = max(floorSeconds, current)
        return min(seconds, floor)
    }
}
