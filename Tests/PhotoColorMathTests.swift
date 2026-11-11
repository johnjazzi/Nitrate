import Foundation
import Testing
import simd

struct PhotoColorMathTests {
    private func close(_ a: Double, _ b: Double, tolerance: Double = 1e-8) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func independentNonNeutralVectorsPreserveRGBChannelOrder() throws {
        let result = try PhotoColorMath.transform(linearSRGB: SIMD3(0.8, 0.2, 0.05))
        #expect(close(result.appleWideGamutLinear.x, 0.5449810163310871))
        #expect(close(result.appleWideGamutLinear.y, 0.21742797765710212))
        #expect(close(result.appleWideGamutLinear.z, 0.09341283781677659))
        let second = try PhotoColorMath.transform(linearSRGB: SIMD3(0.1, 0.6, 0.3))
        #expect(close(second.appleWideGamutLinear.x, 0.25618521567304786))
        #expect(close(second.appleWideGamutLinear.y, 0.5289195482037624))
        #expect(close(second.appleWideGamutLinear.z, 0.33390023057642054))
    }

    @Test func matrixPreservesNeutralAxis() throws {
        for level in [0.0, 0.18, 1.0, 4.0] {
            let v = try PhotoColorMath.transform(linearSRGB: SIMD3(repeating: level)).appleWideGamutLinear
            #expect(close(v.x, level))
            #expect(close(v.y, level))
            #expect(close(v.z, level))
        }
    }

    @Test func appleLog2BlackBranchGrayAndSuperwhiteReferences() throws {
        let references: [(Double, Double)] = [
            (0, 0.1504764523), (0.009999, 0.20854903524444016), (0.01, 0.2085553187),
            (0.18, 0.4882724585), (1, 0.6945529831), (2, 0.7794674259),
            (4, 0.8646759795), (8, 0.9500323841), (12, 0.9999999784)
        ]
        for (linear, encoded) in references {
            let result = try PhotoColorMath.transform(linearSRGB: SIMD3(repeating: linear))
            #expect(close(result.appleLog2.x, encoded, tolerance: 2e-7), "linear=\(linear)")
        }
    }

    @Test func logDecodeRoundTripsLinearDomainWhenAvailable() throws {
        for linear in [0.0, 0.001, 0.009999, 0.01, 0.18, 1.0, 2.0, 8.0, 12.0] {
            let code = try PhotoColorMath.transform(linearSRGB: SIMD3(repeating: linear)).appleLog2.x
            #expect(close(PhotoColorMath.appleLog2Decode(code), linear, tolerance: 2e-7))
        }
    }

    @Test func negativePolicyClipsAfterMatrixAndCountsComponents() throws {
        // The declared matrix is positive. This extended-linear vector produces
        // a negative red component only after gamut conversion.
        let result = try PhotoColorMath.transform(linearSRGB: SIMD3(-1, 0, 1))
        #expect(result.negativeChannelClipCount == 1)
        #expect(result.appleWideGamutLinear.x == 0)
        #expect(result.appleWideGamutLinear.y > 0)
        #expect(result.appleWideGamutLinear.z > 0)
    }

    @Test func noUpperLinearClampAndCountsLUTDomainClips() throws {
        let result = try PhotoColorMath.transform(linearSRGB: SIMD3(repeating: 16))
        #expect(close(result.appleWideGamutLinear.x, 16))
        #expect(close(result.appleWideGamutLinear.y, 16))
        #expect(close(result.appleWideGamutLinear.z, 16))
        #expect(result.lutDomainClipCount == 3)
    }

    @Test func normalizationIsExplicitVersionedAndUncalibratedByDefault() throws {
        #expect(PhotoExposureNormalization.uncalibrated.revision == 1)
        #expect(PhotoExposureNormalization.uncalibrated.linearGain == 1)
        #expect(PhotoExposureNormalization.uncalibrated.isCalibrated == false)
        let doubled = try PhotoColorMath.transform(linearSRGB: SIMD3(repeating: 0.18),
                                               normalization: .init(revision: 7, linearGain: 2, isCalibrated: false))
        #expect(close(doubled.appleWideGamutLinear.x, 0.36))
    }

    @Test func nonFiniteInputsAndInvalidNormalizationAreRejected() throws {
        #expect(PhotoColorMath.validate(linearSRGB: SIMD3(.nan, 0, 0), normalization: .uncalibrated) == false)
        #expect(PhotoColorMath.validate(linearSRGB: SIMD3(0, .infinity, 0), normalization: .uncalibrated) == false)
        #expect(PhotoColorMath.validate(linearSRGB: .zero,
                                        normalization: .init(revision: 0, linearGain: 1, isCalibrated: false)) == false)
        #expect(PhotoColorMath.validate(linearSRGB: .zero,
                                        normalization: .init(revision: 1, linearGain: -0.5, isCalibrated: false)) == false)
    }
}
