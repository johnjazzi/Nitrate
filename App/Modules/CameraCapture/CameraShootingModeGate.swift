import Foundation

/// Why the shooting-mode row is refusing a change, in the operator's words.
///
/// The row greys out for ten independent reasons — a take starting, a take
/// running, a photo capture, a frame-rate change, a capture-profile rebuild, a
/// lens switch, a pending configuration, a camera that is not ready, a camera
/// that is not running. Any one of them dims the same letters, and a control that
/// cannot say which one it is has no feedback at all: the operator is left
/// tapping a greyed "V" with nothing to explain it. The reason is the single
/// source of truth for both the refusal and the message shown with it.
struct CameraShootingModeGate: Equatable {
    let isLifecycleActive: Bool
    let isCameraConfigured: Bool
    let isConfigurationInFlight: Bool
    let isChangingFrameRate: Bool
    let isChangingCaptureProfile: Bool
    let isSwitchingCameraLens: Bool
    let isPhotoCaptureBusy: Bool
    let isStartingRecording: Bool
    let isRecording: Bool
    let isStoppingRecording: Bool

    /// Nil when the row may change mode.
    var reason: String? {
        guard isLifecycleActive else { return "Camera is not running" }
        guard isCameraConfigured else { return "Camera is not ready yet" }
        guard !isConfigurationInFlight else { return "Camera is still configuring" }
        if isStartingRecording { return "Starting the take…" }
        if isRecording { return "Recording — stop the take to change modes" }
        if isStoppingRecording { return "Finishing the take…" }
        if isPhotoCaptureBusy { return "Capturing a photo…" }
        if isChangingFrameRate { return "Changing frame rate…" }
        if isChangingCaptureProfile { return "Changing the camera…" }
        if isSwitchingCameraLens { return "Switching camera…" }
        return nil
    }

    var isAllowed: Bool { reason == nil }
}
