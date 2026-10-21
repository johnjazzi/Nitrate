import Foundation
import Testing

/// The 60-eligible format selector: 4K, Apple Log 2, 10-bit bi-planar, whose
/// frame-rate ranges include 60. The 24 selector stays unchanged.
struct DaylightCapturePolicyTests {
    private typealias Candidate = CameraCaptureFormatPolicy.Candidate

    @Test func sixtySelectorRequiresASixtyFpsRange() {
        let candidates: [Candidate] = [
            // 4K Log2 10-bit 420 but only 24 fps advertised.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: false),
            // 4K Log2 10-bit 420 with 60 fps — eligible.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes(in: candidates) == [1])
    }

    @Test func sixtySelectorRejectsNonFourKNonLogOrEightBit() {
        let candidates: [Candidate] = [
            .init(width: 1920, height: 1080, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: false, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: false, isTenBitBiPlanar422: false, supports60FPS: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes(in: candidates).isEmpty)
    }

    @Test func sixtySelectorOrdersFourTwentyBeforeFourTwentyTwo() {
        let candidates: [Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true, supports60FPS: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes(in: candidates) == [1, 0])
    }

    @Test func twentyFourSelectorIsUnchangedAndIgnoresSixtyCapability() {
        let candidates: [Candidate] = [
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true),
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true)
        ]
        // 24 selection is driven only by supports24FPS/geometry/bitdepth, and
        // 420 is preferred before 422.
        #expect(CameraCaptureFormatPolicy.appleLog2CandidateIndexes(in: candidates) == [1, 0])
        // A 24-only candidate is NOT 60-eligible.
        #expect(CameraCaptureFormatPolicy.appleLog2SixtyCandidateIndexes(in: candidates).isEmpty)
    }
}
