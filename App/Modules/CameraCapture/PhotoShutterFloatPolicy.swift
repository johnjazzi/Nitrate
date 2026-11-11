import Foundation

/// The one rule left on an auto-floating Photo shutter: how slow it may go.
///
/// Pinning the ISO no longer pins the shutter. The operator who holds the ISO is
/// holding *sensitivity*; the shutter is then the metering's only lever and it
/// floats to reach the compensation, exactly as the device's own auto exposure
/// would. A held shutter is a separate, explicit choice on the shutter rail.
enum PhotoShutterFloatPolicy {
    /// The slowest Photo exposure, in seconds: 1/8. It is both the auto-float
    /// limit and the rail's own end, because AVFoundation refuses the exposure
    /// writes below it on this hardware — past 1/2s the setter never acknowledges
    /// and EV changes stop landing.
    static let floorSeconds: Double = 1.0 / 8.0

    /// Clamp a floated speed to the 1/8s limit without shortening an exposure the
    /// operator already set slower than it.
    static func clampedFloat(_ seconds: Double, current: Double) -> Double {
        let floor = max(floorSeconds, current)
        return min(seconds, floor)
    }
}
