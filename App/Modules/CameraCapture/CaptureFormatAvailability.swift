import AVFoundation
import Foundation

/// Hardware answer to "can this iPhone record this capture mode?".
///
/// Kept out of `CaptureFormat` on purpose: the preference stays Foundation-only
/// so its policy tests compile on macOS, while the AVFoundation question lives
/// here where only the app target needs it.
enum CaptureFormatAvailability {
    /// Formats this device can actually deliver at `fps`. The UHD baseline is
    /// always first; an option the hardware cannot honour is absent rather than
    /// shown and then refused.
    static func availableFormats(on device: AVCaptureDevice? = defaultDevice,
                                 fps: Double = 24) -> [CaptureFormat] {
        guard let device else { return [.uhd16x9] }
        let supported = CaptureFormat.allCases.filter { supports($0, on: device, fps: fps) }
        // A device that cannot even do UHD must still present one row; the
        // session will refuse the take with its own error.
        return supported.contains(.uhd16x9) ? supported : [.uhd16x9]
    }

    /// Whether `format` has a matching Apple Log 2 format on `device`.
    static func supports(_ format: CaptureFormat, on device: AVCaptureDevice? = defaultDevice,
                         fps: Double = 24) -> Bool {
        guard let device else { return false }
        guard #available(iOS 26.0, *) else { return false }
        return device.formats.contains { candidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            guard dimensions.width == format.width, dimensions.height == format.height else {
                return false
            }
            guard candidate.supportedColorSpaces.contains(.appleLog2) else { return false }
            guard candidate.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= fps && $0.maxFrameRate >= fps
            }) else { return false }
            let subtype = CMFormatDescriptionGetMediaSubType(candidate.formatDescription)
            let is422 = subtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
                || subtype == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            if format.requiresTenBit422 { return is422 }
            let is420 = subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            return is422 || is420
        }
    }

    private static var defaultDevice: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}
