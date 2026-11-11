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

    @Test func oneTwentySelectorRequiresARealOneTwentyRangeNotSixty() {
        let candidates: [Candidate] = [
            // 60-only: eligible for 60, never for 120.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true),
            // 120-capable 420, preferred.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar420: true, supports60FPS: true, supports120FPS: true),
            // 120-capable 422, after the 420 candidate.
            .init(width: 3840, height: 2160, supportsAppleLog2: true, supports24FPS: true,
                  isTenBitBiPlanar422: true, supports60FPS: false, supports120FPS: true)
        ]
        #expect(CameraCaptureFormatPolicy.appleLog2EligibleCandidateIndexes(in: candidates, fps: 120) == [1, 2])
        // The 60-only format is chosen for 60 and 24, so the rate-aware selector
        // is the same one 24/60 already used.
        #expect(CameraCaptureFormatPolicy.appleLog2EligibleCandidateIndexes(in: candidates, fps: 60) == [0, 1])
        #expect(CameraCaptureFormatPolicy.appleLog2EligibleCandidateIndexes(in: candidates, fps: 24) == [0, 1, 2])
        // No 120-capable format means no 120 — never a silent 60 fallback.
        let sixtyOnly: [Candidate] = [candidates[0]]
        #expect(CameraCaptureFormatPolicy.appleLog2EligibleCandidateIndexes(in: sixtyOnly, fps: 120).isEmpty)
    }

    @Test func unknownRatesAreNeverTreatedAsSupported() {
        let candidate = Candidate(width: 3840, height: 2160, supportsAppleLog2: true,
                                  supports24FPS: true, isTenBitBiPlanar420: true,
                                  supports60FPS: true, supports120FPS: true)
        #expect(candidate.supports(fps: 24))
        #expect(candidate.supports(fps: 60))
        #expect(candidate.supports(fps: 120))
        #expect(!candidate.supports(fps: 30))
        #expect(!candidate.supports(fps: 0))
    }
}
