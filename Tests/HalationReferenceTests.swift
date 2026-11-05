import Foundation
import Testing

/// Where halation reaches FULL contribution, and why it moves.
///
/// The knees are authored for Apple Log 2, which carries about 12x diffuse
/// white, and the reference is the 8x point of that curve. A raw photo is not a
/// Log frame: a single exposure CLIPS at its own white. Measured across 35 DSLR
/// raws (29 Nikon D700 NEF, 6 Sony NEX-6 ARW) the brightest 0.01% of pixels sat
/// between 0.5x and 3.7x white, so against a fixed 8x halation could reach only
/// 7-48% of its range — the faint halo those files showed.
///
/// The fix is one rule: a still is measured against the ceiling it actually
/// carries; a video frame keeps the authored constant. Clipped light is clipped,
/// so a clipped sky blooms like clipped anything else.
struct HalationReferenceTests {
    private static func lift(_ stops: Float) -> Float { powf(2, stops) }

    @Test func videoKeepsTheAuthoredReference() {
        // No measurement is passed for video, so nothing about a take changed.
        #expect(SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 0) == 8)
        for stops: Float in [1.1, 2.99, 3.99, 4.2] {
            let expected = 8 * Self.lift(stops)
            let actual = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: stops)
            #expect(abs(actual - expected) < 0.01,
                    "lift \(stops) must keep the authored reference: \(actual) vs \(expected)")
        }
    }

    @Test func aDslrRawIsMeasuredAgainstItsOwnCeiling() {
        // Real numbers: DSC_4224.NEF p99.99 = 3.48 at 1.10 EV of lift.
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 1.10,
                                                                        headroom: 3.48)
        #expect(abs(reference - 3.48) < 0.001, "taken as measured, in the frame's own units")
        #expect(reference < 8 * Self.lift(1.10), "and well below the authored 8x")
    }

    @Test func theFloorIsOneWhiteSoTheKneesCanStillFire() {
        // DSC_4301.NEF measures 1.09 lifted — near enough to white that a lower
        // anchor would put the red knee below every ordinary surface.
        let floor = Self.lift(3.99)
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                       headroom: 0.4)
        #expect(abs(reference - floor) < 0.01, "never anchored below one white")
    }

    @Test func aBrightFileIsAnchoredToItsMeasureAndCappedAtTheAuthoredPoint() {
        // IMG_2527.DNG (ProRAW) measures 74.94 lifted = 4.72x unlifted white. That
        // is BELOW the authored 8x, so uniform anchoring does move ProRAW: its
        // halation reaches full contribution at its own ceiling, 1.69x earlier
        // than before. Held here so the change is deliberate and visible.
        let authored = 8 * Self.lift(3.99)
        let proRAW = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                     headroom: 74.94)
        #expect(abs(proRAW - 74.94) < 0.01, "measured, not authored")
        #expect(abs(authored / proRAW - 1.69) < 0.02, "a 1.69x stronger anchor for ProRAW")

        // A file brighter than the authored point cannot push the reference past
        // it: 8x is the ceiling of the rule, and the knees were authored for it.
        let brighter = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                      headroom: 500)
        #expect(abs(brighter - authored) < 0.01, "the authored point is the cap")
    }

    @Test func aNonFiniteMeasurementFallsBackToTheAuthoredReference() {
        let authored = 8 * Self.lift(1.1)
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 1.1,
                                                                        headroom: .nan)
        #expect(abs(reference - authored) < 0.01, "garbage in must not move the anchor")
    }
}
