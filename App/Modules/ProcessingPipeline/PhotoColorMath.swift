import Foundation
import simd

struct PhotoExposureNormalization: Sendable, Equatable {
    let revision: Int
    let linearGain: Double
    let isCalibrated: Bool
    static let uncalibrated = PhotoExposureNormalization(revision: 1, linearGain: 1, isCalibrated: false)
}

struct PhotoColorTransformResult: Sendable, Equatable {
    let appleWideGamutLinear: SIMD3<Double>
    let appleLog2: SIMD3<Double>
    let negativeChannelClipCount: Int
    let lutDomainClipCount: Int
}

enum PhotoColorMathError: Error, Equatable { case nonFiniteInput, invalidNormalization }

/// Photo-only adapter derived from the published primaries/D65 and pinned
/// generator/OCIO Apple Log 2 curve. Exposure normalization is not calibrated.
enum PhotoColorMath {
    static let adapterRevision = 1
    static let linearSRGBToAppleWideGamut = simd_double3x3(rows: [
        SIMD3(0.6081040099936037, 0.25935339223922904, 0.13254259776716695),
        SIMD3(0.06231553359437752, 0.8046088497421263, 0.13307561666349632),
        SIMD3(0.03113261473948977, 0.13375584508106164, 0.8351115401794487)
    ])

    static func validate(linearSRGB: SIMD3<Double>, normalization: PhotoExposureNormalization) -> Bool {
        linearSRGB.x.isFinite && linearSRGB.y.isFinite && linearSRGB.z.isFinite
            && normalization.revision > 0 && normalization.linearGain.isFinite && normalization.linearGain > 0
    }

    static func transform(linearSRGB: SIMD3<Double>,
                          normalization: PhotoExposureNormalization = .uncalibrated) throws -> PhotoColorTransformResult {
        guard linearSRGB.x.isFinite, linearSRGB.y.isFinite, linearSRGB.z.isFinite else {
            throw PhotoColorMathError.nonFiniteInput
        }
        guard normalization.revision > 0, normalization.linearGain.isFinite, normalization.linearGain > 0 else {
            throw PhotoColorMathError.invalidNormalization
        }
        let converted = (linearSRGBToAppleWideGamut * linearSRGB) * normalization.linearGain
        guard converted.x.isFinite, converted.y.isFinite, converted.z.isFinite else {
            throw PhotoColorMathError.nonFiniteInput
        }
        let negativeCount = [converted.x, converted.y, converted.z].filter { $0 < 0 }.count
        let positive = SIMD3(max(0, converted.x), max(0, converted.y), max(0, converted.z))
        let code = SIMD3(appleLog2Encode(positive.x), appleLog2Encode(positive.y), appleLog2Encode(positive.z))
        return PhotoColorTransformResult(appleWideGamutLinear: positive, appleLog2: code,
            negativeChannelClipCount: negativeCount,
            lutDomainClipCount: [code.x, code.y, code.z].filter { $0 > 1 }.count)
    }

    static func appleLog2Encode(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return .nan }
        if value < 0.01 { return 47.28711236 * pow(value + 0.05641088, 2) }
        return 0.69336945 + 0.08550479 * log2(value + 0.00964052)
    }

    static func appleLog2Decode(_ code: Double) -> Double {
        guard code.isFinite else { return .nan }
        if code < appleLog2Encode(0.01) {
            return max(0, sqrt(max(0, code) / 47.28711236) - 0.05641088)
        }
        return max(0, pow(2, (code - 0.69336945) / 0.08550479) - 0.00964052)
    }
}
