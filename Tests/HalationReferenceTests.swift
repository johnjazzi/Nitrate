import Foundation
import Testing

/// Where halation reaches FULL contribution, and why it is a rule now.
///
/// It is 10x diffuse white — `log2(10)` = 3.32 stops above white — one value for
/// stills and takes alike, pegged inside Apple Log 2's ~12x recorded range so an
/// 11x specular reaches full contribution without swamping the graded frame. Both
/// ends of the ramp (an onset and this reference) are therefore authored in the
/// same units, which is what lets a still and a take of one scene grade alike.
///
/// The reference used to be measured for stills — a share of the file's own
/// p99.99 — on the reasoning that a single-exposure raw clips at its own white and
/// never reaches 10x. It does not, but the measurement made the ramp depend on the
/// brightest pixels of that particular file: for a fused ProRAW the anchor landed
/// near 0.74x white against a take's 10x, so a still began glowing far earlier
/// than the video shot beside it. One rule, no measurement — and now no scale
/// either: a decode lift moves the FRAME (`frameWhiteStops`), not the reference.
struct HalationReferenceTests {
    private static let log2Ten: Float = 3.3219

    @Test func theAuthoredPointIsTenTimesWhite() {
        #expect(abs(SpatialEffectsStage.halationReferenceStops - Self.log2Ten) < 0.001)
        #expect(abs(powf(2, SpatialEffectsStage.halationReferenceStops) - 10) < 0.01,
                "the reference is 10x diffuse white")
    }

    @Test func theReferenceSitsInsideTheRecordedRange() {
        // Apple Log 2 records to ~12x white, so 10x is inside the range: a specular
        // can actually reach full contribution instead of being cut off by the clip.
        #expect(SpatialEffectsStage.halationReferenceStops
                < log2(SpatialEffectsStage.appleLog2ClipWhite),
                "the reference must be reachable within the recorded range")
        #expect(SpatialEffectsStage.halationReferenceStops
                > SpatialEffectsStage.authoredOnsets.z,
                "and above every onset, or a layer has no ramp")
    }

    @Test func aBrightProRAWNoLongerHalvesItsOwnRamp() {
        // IMG_2527.DNG measures 74.94 in its own lifted frame (4.72x its unlifted
        // white) at 3.99 EV of lift. The measured anchor this replaced made the
        // ramp's top a share of that peak, which landed near 0.74x unlifted white
        // — an eighth of a take's 10x, which is the "stills glow first" mismatch.
        // Nothing about the file reaches the rule any more: the same 10x applies to
        // both paths, and the file's lift appears only as a frame offset.
        let oldAnchorWhite: Float = (74.94 * 0.15625) / powf(2, 3.99)
        let referenceWhite = powf(2, SpatialEffectsStage.halationReferenceStops)
        #expect(abs(referenceWhite - 10) < 0.01)
        #expect(oldAnchorWhite < referenceWhite / 8,
                "the old measurement sat far below the authored point (\(oldAnchorWhite) vs \(referenceWhite))")
        // The lift moves the frame the mask reads, by exactly the lift.
        for stops: Float in [1.1, 2.99, 3.99, 4.2] {
            let unlifted = SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0)
            let lifted = SpatialEffectsStage.frameWhiteStops(sceneLiftStops: stops)
            #expect(abs(lifted - unlifted - stops) < 0.0001,
                    "lift \(stops) must move the frame by \(stops)")
        }
    }
}
