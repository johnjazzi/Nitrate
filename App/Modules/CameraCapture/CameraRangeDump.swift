#if DEBUG
import AVFoundation
import CoreMedia
import Foundation

/// Prints the ISO and frame-rate range of every camera and format the device
/// exposes, so an ISO cap can be set from measured hardware rather than assumed.
///
/// Enabled with `--dump-camera-ranges`. Run it on the phone and read the console
/// (`xcrun devicectl device process launch --console`); a simulator has no real
/// ranges, and the numbers differ per camera and per format.
enum CameraRangeDump {
    static func dumpIfRequested() {
        guard CommandLine.arguments.contains("--dump-camera-ranges") else { return }
        for lens in [AVCaptureDevice.DeviceType.builtInWideAngleCamera,
                     .builtInUltraWideCamera, .builtInTelephotoCamera] {
            dump(lens, position: .back)
        }
        dump(.builtInWideAngleCamera, position: .front)
    }

    private static func dump(_ type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video,
                                                       position: position)
        guard let device = session.devices.first else {
            print("RANGE-DUMP \(type.rawValue) unavailable")
            return
        }
        print("RANGE-DUMP \(type.rawValue) formats=\(device.formats.count) name=\(device.localizedName)")
        for (index, format) in device.formats.enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let rates = format.videoSupportedFrameRateRanges
                .map { Int($0.minFrameRate.rounded())...Int($0.maxFrameRate.rounded()) }
            let supports24 = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 24 && $0.maxFrameRate >= 24
            }
            let supports60 = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 60 && $0.maxFrameRate >= 60
            }
            var log2 = "no"
            if #available(iOS 26.0, *) {
                log2 = format.supportedColorSpaces.contains(.appleLog2) ? "yes" : "no"
            }
            print("RANGE-DUMP   #\(index) \(dimensions.width)x\(dimensions.height) "
                  + "sub=\(fourCharCode(subtype)) iso=\(format.minISO)...\(format.maxISO) "
                  + "exposure=\(format.minExposureDuration.seconds)...\(format.maxExposureDuration.seconds) "
                  + "fps=\(rates.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")) "
                  + "24=\(supports24) 60=\(supports60) log2=\(log2)")
        }
    }

    private static func fourCharCode(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let scalars = bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." }
        return String(scalars)
    }
}
#endif
