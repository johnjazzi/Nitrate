import Foundation
import simd

/// File estimate only: center-weighted arithmetic mean of scene-linear luminance
/// relative to 18% gray. Not EV100, illuminance, or a camera auto-pull input.
/// Nonfinite samples are unavailable, not black; a black-only frame has no finite EV.
enum DevelopExposureMeter {
    static func offsetEV(luminance: [Double], width: Int, height: Int) -> Double? {
        guard width > 0, height > 0, width <= Int.max / height,
              luminance.count == width * height else { return nil }
        var total = 0.0, weights = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let value = luminance[y * width + x]
                guard value.isFinite, value >= 0 else { continue }
                let dx = (Double(x) + 0.5) / Double(width) * 2 - 1
                let dy = (Double(y) + 0.5) / Double(height) * 2 - 1
                // Smooth center emphasis with nonzero edge contribution.
                let weight = 1 + 4 * exp(-2 * (dx * dx + dy * dy))
                total += value * weight
                weights += weight
            }
        }
        guard weights > 0, total.isFinite, total > 0 else { return nil }
        let result = log2(total / weights / 0.18)
        return result.isFinite ? result : nil
    }

    static func linearSRGBLuminance(_ rgb: SIMD3<Double>) -> Double {
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return .nan }
        return max(0, simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722)))
    }

    static func appleLog2Luminance(_ codes: SIMD3<Double>) -> Double {
        guard codes.x.isFinite, codes.y.isFinite, codes.z.isFinite else { return .nan }
        let awg = SIMD3(PhotoColorMath.appleLog2Decode(codes.x),
                        PhotoColorMath.appleLog2Decode(codes.y),
                        PhotoColorMath.appleLog2Decode(codes.z))
        // Same declared AWG / D65 basis as the production RAW->Log2 adapter.
        return linearSRGBLuminance(PhotoColorMath.linearSRGBToAppleWideGamut.inverse * awg)
    }

    /// Numerical measurement mirror of hlg-input.h / spatial.metal only. Rendering
    /// always uses PipelineRenderer's actual HLG adapter, never this approximation.
    /// Inputs are unpacked ten-bit VIDEO-range code values (not normalized unorm).
    static func hlgLuminance(y: Double, cb: Double, cr: Double) -> Double {
        guard y.isFinite, cb.isFinite, cr.isFinite else { return .nan }
        let luma = (y - 64) / 876
        let blue = (cb - 512) / 896, red = (cr - 512) / 896
        let codes = SIMD3(luma + 1.4746 * red,
                          luma - 0.164553 * blue - 0.571353 * red,
                          luma + 1.8814 * blue)
        func scene(_ code: Double) -> Double {
            let magnitude = abs(code)
            let value = magnitude <= 0.5 ? magnitude * magnitude / 3
                : (exp((magnitude - 0.55991073) / 0.17883277) + 0.28466892) / 12
            return (code < 0 ? -value : value) * 3.7741181275
        }
        // BT.2020 scene-linear luminance; the house normalization matches export.
        return max(0, simd_dot(SIMD3(scene(codes.x), scene(codes.y), scene(codes.z)),
                               SIMD3(0.2627, 0.6780, 0.0593)))
    }
}
