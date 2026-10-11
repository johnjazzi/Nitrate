import AVFoundation

/// AD-13: Tap-to-focus and portrait mode management.
/// Implements CAP-13 — focus works like native iPhone camera.
@MainActor
final class FocusManager {
    private let session: CameraSession
    var onError: ((Error) -> Void)?
    private(set) var isPortraitModeEnabled = false
    private(set) var isPortraitModeSupported = false

    var supportsDepth: Bool {
        session.activeDevice?.activeFormat.supportedDepthDataFormats.isEmpty == false
    }

    init(session: CameraSession) {
        self.session = session
        self.isPortraitModeSupported = supportsDepth
    }

    /// Set device focus point of interest (normalized coordinates 0–1).
    /// Taps the preview at a point; FocusManager converts to device coordinates and sets focus.
    func focus(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        session.setFocusAndExposurePoint(devicePoint)
    }

    /// Toggle portrait mode. Only available on devices with depth support.
    func togglePortraitMode() {
        guard supportsDepth else { return }
        isPortraitModeEnabled.toggle()
        session.setPortraitMode(isEnabled: isPortraitModeEnabled) { [weak self] error in
            if let error { self?.onError?(error) }
        }
    }
}
