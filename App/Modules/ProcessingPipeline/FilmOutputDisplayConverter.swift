import CoreImage
import CoreGraphics

/// Shared final-output interpretation for Photo delivery and frozen video Debug.
/// Finished film channels are Rec.709-primary RGB encoded with gamma 2.4, not
/// linear RGB and not sRGB code values. Intermediate Log/graded diagnostic
/// images must NOT be presented as delivery color without the appropriate decode.
enum FilmOutputDisplayConverter {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .outputColorSpace: srgbSpace,
        .cacheIntermediates: false
    ])
    private static let gammaDecode = CIColorKernel(source: """
        kernel vec4 filmOutputToLinear(__sample s) {
            return vec4(pow(max(s.rgb,vec3(0.0)),vec3(2.4)),s.a);
        }
        """)

    enum ConversionError: Error { case gammaDecodeUnavailable, imageUnavailable }

    /// Input must preserve the LUT's numeric channels (tag encoded images with
    /// extendedLinearSRGB solely to prevent an implicit second transfer decode).
    static func linearImage(fromGamma24 image: CIImage) throws -> CIImage {
        guard let decoded = gammaDecode?.apply(extent: image.extent, arguments: [image]) else {
            throw ConversionError.gammaDecodeUnavailable
        }
        return decoded
    }

    /// Decode gamma 2.4 once, then explicitly encode/tag the drawable image sRGB.
    static func makeSRGBImage(fromGamma24 image: CIImage) throws -> CGImage {
        let linear = try linearImage(fromGamma24: image)
        guard let result = context.createCGImage(linear, from: linear.extent, format: .RGBA8, colorSpace: srgbSpace) else {
            throw ConversionError.imageUnavailable
        }
        return result
    }
}
