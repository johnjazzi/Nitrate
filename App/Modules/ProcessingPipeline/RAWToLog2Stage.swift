import Foundation
import CoreImage
import simd

/// CPU reference for the photo-only linear-sRGB -> Apple Wide Gamut -> Apple Log 2 adapter.
/// The default gain is explicitly uncalibrated; do not infer exposure calibration from this transform.
enum RAWToLog2Stage {
    static let revision = 1

    /// GPU adapter used by real RAW development and linear-fixture regressions.
    static func apply(_ image: CIImage) throws -> CIImage {
        let m = PhotoColorMath.linearSRGBToAppleWideGamut
        func row(_ n: Int) -> String {
            "\(m[0][n])*s.r+\(m[1][n])*s.g+\(m[2][n])*s.b"
        }
        let source = """
        kernel vec4 photoToLog(__sample s) {
            vec3 v=max(vec3(\(row(0)),\(row(1)),\(row(2))),vec3(0.0));
            vec3 l=vec3(v.r<0.01 ? 47.28711236*pow(v.r+0.05641088,2.0) : 0.69336945+0.08550479*log2(v.r+0.00964052),
                        v.g<0.01 ? 47.28711236*pow(v.g+0.05641088,2.0) : 0.69336945+0.08550479*log2(v.g+0.00964052),
                        v.b<0.01 ? 47.28711236*pow(v.b+0.05641088,2.0) : 0.69336945+0.08550479*log2(v.b+0.00964052));
            return vec4(l,s.a);
        }
        """
        guard let kernel = CIColorKernel(source: source),
              let result = kernel.apply(extent: image.extent, arguments: [image]) else {
            throw DevelopmentPhotoRenderer.RenderError.decode("Photo Log adapter unavailable")
        }
        return result
    }

    static func apply(_ linearSRGB: SIMD3<Double>, normalization: PhotoExposureNormalization = .uncalibrated) throws -> PhotoColorTransformResult {
        try PhotoColorMath.transform(linearSRGB: linearSRGB, normalization: normalization)
    }
}
