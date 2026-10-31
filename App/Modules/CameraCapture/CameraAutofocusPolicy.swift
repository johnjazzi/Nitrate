import Foundation

/// Chooses the focus mode a point-of-interest request installs.
///
/// The operator's contract is that the selected circle keeps correcting its own
/// focus as the scene distance changes, not that it focuses once when tapped.
/// Continuous autofocus at `focusPointOfInterest` is the only mode that does
/// that, so it is preferred wherever the device supports it. A device without it
/// keeps the one-shot mode, which still focuses at the point but only once per
/// request — the app cannot claim a continuous behaviour the hardware has not
/// reported.
///
/// Pure and AVFoundation-free, like the other camera policy seams, so the
/// decision is exercised in the RenderCLI target without an `AVCaptureDevice`.
enum CameraAutofocusPolicy {
    enum Mode: Equatable, Sendable {
        /// Keep refocusing at the selected point while the scene changes.
        case continuous
        /// Focus once at the selected point; the device has no continuous AF.
        case single
    }

    /// `nil` when the device supports neither mode, so the caller leaves the
    /// device's focus alone instead of writing a mode it rejects.
    static func mode(supportsContinuous: Bool, supportsSingle: Bool) -> Mode? {
        if supportsContinuous { return .continuous }
        if supportsSingle { return .single }
        return nil
    }
}
