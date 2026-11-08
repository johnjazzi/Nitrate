import AVFoundation
import Foundation

/// Hardware answer to "can this camera record this capture mode?".
/// Shares the session selector: native geometry, permitted profile, ten-bit
/// layout and the requested rate must all match. No model allowlist or HDR flag.
enum CaptureFormatAvailability {
    static func availableFormats(on device: AVCaptureDevice? = defaultDevice,
                                 fps: Double = 24) -> [CaptureFormat] {
        guard let device else { return [] }
        return CaptureFormat.allCases.filter { supports($0, on: device, fps: fps) }
    }

    static func supports(_ format: CaptureFormat, on device: AVCaptureDevice? = defaultDevice,
                         fps: Double = 24) -> Bool {
        guard let device, fps.isFinite,
              let mode = CameraFrameRate.allCases.first(where: { Double($0.fps) == fps }) else { return false }
        return !CameraSession.captureFormats(for: device, mode: mode, captureFormat: format).isEmpty
    }

    private static var defaultDevice: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}
