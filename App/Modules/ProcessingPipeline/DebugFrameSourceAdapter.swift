import CoreImage
import CoreVideo
import Foundation

/// Adapts a processed camera snapshot to the existing video renderer's Apple
/// Wide Gamut / Apple Log 2 numeric input. Storage layout never selects a domain.
/// This cannot recover RAW scene values, exposure, noise, or white balance lost
/// to the camera ISP. The source is a color-space snapshot from the capture owner.
enum DebugFrameSourceAdapter {
    enum SourceColorSpace: Sendable, Equatable {
        case appleLog2
        case sRGB
        case displayP3
    }

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let linearContext = CIContext(options: [
        .workingColorSpace: linearSpace,
        .outputColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf.rawValue,
        .cacheIntermediates: false
    ])
    private static let codeContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    static func rgbaHalfBuffer(from pixelBuffer: CVPixelBuffer,
                               sourceColorSpace: SourceColorSpace) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        // Only already-Log half buffers can bypass decoding. An SDR half buffer
        // has exactly the same storage but entirely different channel semantics.
        if sourceColorSpace == .appleLog2,
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf {
            return pixelBuffer
        }
        var destination: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &destination) == kCVReturnSuccess,
            let destination else { return nil }

        switch sourceColorSpace {
        case .appleLog2:
            // Preserve the established Log YCbCr/layout conversion. No transfer
            // decode, gamut conversion, tone mapping, or second Log encoding.
            let codes = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
            codeContext.render(codes, to: destination, bounds: codes.extent, colorSpace: nil)
        case .sRGB, .displayP3:
            let name = sourceColorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
            guard let sourceSpace = CGColorSpace(name: name) else { return nil }
            // Explicit capture color space overrides any stale RGB attachment.
            // Core Image still uses the buffer's actual YCbCr matrix/range metadata
            // for YUV decoding; format alone is not a transfer/color-space tag.
            let source = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: sourceSpace])
            // Core Image decodes the source transfer and primaries to extended
            // linear sRGB before this shared RAW->AWG/Log kernel executes. Render
            // into the SAME linear space to preserve the kernel's encoded numbers.
            guard let prepared = try? RAWToLog2Stage.apply(source) else { return nil }
            linearContext.render(prepared, to: destination, bounds: prepared.extent, colorSpace: linearSpace)
        }
        return destination
    }
}
