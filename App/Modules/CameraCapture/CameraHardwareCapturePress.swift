import Foundation

/// A full press captures once on release. A cancelled or hidden-camera press
/// cannot become a shutter action after the camera becomes available again.
struct CameraHardwareCapturePress {
    enum Phase { case began, ended, cancelled }
    private var isArmed = false

    mutating func receive(_ phase: Phase, isEnabled: Bool) -> Bool {
        switch phase {
        case .began:
            isArmed = isEnabled
            return false
        case .ended:
            let captures = isArmed && isEnabled
            isArmed = false
            return captures
        case .cancelled:
            reset()
            return false
        }
    }

    mutating func reset() { isArmed = false }
}
