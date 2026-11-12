import Foundation
import Testing

/// Where halation reaches FULL contribution, and why it is a rule now.
///
/// The knees and the reference were both authored for Apple Log 2, which carries
/// about 12x diffuse white; the reference is that curve's 10x point, leaving room
/// for an 11x specular. Stills and takes use it alike.
///
/// It used to be measured for stills — a share of the file's own p99.99 — on the
/// reasoning that a single-exposure raw clips at its own white and never reaches
/// 10x. It does not, but the measurement made the ramp depend on the brightest
/// pixels of that particular file: for a fused ProRAW the anchor landed near
/// 0.7x white against a take's 10x, so a still began glowing far earlier than the
/// video shot beside it. One rule, no measurement.
struct HalationReferenceTests {
    private static func lift(_ stops: Float) -> Float { powf(2, stops) }

    @Test func theAuthoredPointIsTenTimesWhite() {
        #expect(SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 0) == 10)
    }

    @Test func theReferenceScalesWithTheDecodeLift() {
        // The lift is the only thing that moves it, exactly as it moves the knees,
        // so a lifted still is measured against the scene it came from.
        for stops: Float in [1.1, 2.99, 3.99, 4.2] {
            let expected = 10 * Self.lift(stops)
            let actual = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: stops)
            #expect(abs(actual - expected) < 0.01,
                    "lift \(stops) must scale the reference: \(actual) vs \(expected)")
        }
    }

    @Test func aBrightProRAWNoLongerHalvesItsOwnRamp() {
        // IMG_2527.DNG measures 74.94 lifted (4.72x unlifted white) at 3.99 EV of
        // lift. The measured anchor this replaced put the ramp's top at a share of
        // that — near 0.74x white, an eighth of the take's 10x, which is the
        // "stills glow first" mismatch. Nothing about the file reaches the rule
        // any more.
        let measuredAnchorThisReplaced: Float = 74.94 * 0.15625
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99)
        #expect(reference == 10 * Self.lift(3.99))
        #expect(measuredAnchorThisReplaced < reference / 8,
                "the old measurement sat far below the authored point")
    }
}
