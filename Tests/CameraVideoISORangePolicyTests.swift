import Foundation
import Testing

struct CameraVideoISORangePolicyTests {
    @Test func aSingleEligibleFormatKeepsItsOwnRange() {
        // Measured on an iPhone 18 Pro main camera: the Apple Log 2 4K format
        // tops out well below the still format the shared idle graph holds.
        let range = CameraVideoISORangePolicy.range(forCandidates: [55...5280])
        #expect(range == 55...5280)
    }

    @Test func theBandIsTheIntersectionOfTheEligibleFormats() {
        let range = CameraVideoISORangePolicy.range(forCandidates: [55...5280, 80...4096])
        #expect(range == 80...4096)
    }

    @Test func noEligibleFormatYieldsNoBand() {
        #expect(CameraVideoISORangePolicy.range(forCandidates: []) == nil)
    }

    @Test func disjointFormatsYieldNoBandRatherThanAnInvertedOne() {
        #expect(CameraVideoISORangePolicy.range(forCandidates: [55...100, 200...5280]) == nil)
    }

    @Test func invalidCandidatesAreIgnored() {
        // A zero/negative bound is not a usable ISO range; a ClosedRange of NaN
        // cannot even be constructed, so invalid means non-positive here.
        #expect(CameraVideoISORangePolicy.range(forCandidates: [0...0, 55...5280]) == 55...5280)
        #expect(CameraVideoISORangePolicy.range(forCandidates: [0...900]) == nil)
    }

    @Test func perCameraTopsDifferAsMeasuredOnDevice() {
        // The reason the band is resolved per camera instead of from a constant.
        let main = CameraVideoISORangePolicy.range(forCandidates: [55...5280])
        let ultraWide = CameraVideoISORangePolicy.range(forCandidates: [15...3600])
        let telephoto = CameraVideoISORangePolicy.range(forCandidates: [15...7680])
        #expect(main?.upperBound == 5280)
        #expect(ultraWide?.upperBound == 3600)
        #expect(telephoto?.upperBound == 7680)
    }
}
