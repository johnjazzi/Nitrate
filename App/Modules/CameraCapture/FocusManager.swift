import AVFoundation

/// AD-13: Tap-to-focus and portrait mode management.
/// Implements CAP-13 — focus works like native iPhone camera.
@MainActor
final class FocusManager {
    private let device: AVCaptureDevice
    private(set) var isPortraitModeEnabled = false
    private(set) var isPortraitModeSupported = false

    var supportsDepth: Bool {
        device.activeFormat.supportedDepthDataFormats.isEmpty == false
    }

    init(device: AVCaptureDevice) {
        self.device = device
        self.isPortraitModeSupported = supportsDepth
    }

    /// Set device focus point of interest (normalized coordinates 0–1).
    /// Taps the preview at a point; FocusManager converts to device coordinates and sets focus.
    func focus(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        guard device.isFocusPointOfInterestSupported else { return }
        guard device.isFocusModeSupported(.autoFocus) else { return }

        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)

        try? device.lockForConfiguration()
        device.focusPointOfInterest = devicePoint
        device.focusMode = .autoFocus
        device.unlockForConfiguration()
    }

    /// Toggle portrait mode. Only available on devices with depth support.
    func togglePortraitMode() throws {
        guard supportsDepth else { return }
        isPortraitModeEnabled.toggle()
        try applyPortraitMode()
    }

    private func applyPortraitMode() throws {
        try device.lockForConfiguration()
        if isPortraitModeEnabled {
            if let depthFormat = device.activeFormat.supportedDepthDataFormats.first {
                device.activeDepthDataFormat = depthFormat
            }
        } else {
            device.activeDepthDataFormat = nil
        }
        device.unlockForConfiguration()
    }
}