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
        let expected = 3.48 * SpatialEffectsStage.stillAnchorShare
        #expect(abs(reference - expected) < 0.001,
                "anchored to its own ceiling, through the tuned share")
        #expect(reference < 8 * Self.lift(1.10), "and well below the authored 8x")
    }

    @Test func theFloorKeepsADarkFrameFromVeiling() {
        // A frame with almost nothing above white must not push the denominator
        // toward zero: the floor is a share of white, not the measurement.
        let floor = Self.lift(3.99) * SpatialEffectsStage.stillAnchorFloorWhite
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                       headroom: 0.4)
        #expect(abs(reference - floor) < 0.01, "the floor holds the anchor off zero")
    }

    @Test func aBrightFileIsAnchoredToItsMeasureAndCappedAtTheAuthoredPoint() {
        // IMG_2527.DNG (ProRAW) measures 74.94 lifted = 4.72x unlifted white. That
        // is BELOW the authored 8x, so uniform anchoring does move ProRAW: its
        // halation reaches full contribution at its own ceiling, 1.69x earlier
        // than before. Held here so the change is deliberate and visible.
        let authored = 8 * Self.lift(3.99)
        let proRAW = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                     headroom: 74.94)
        let expected = 74.94 * SpatialEffectsStage.stillAnchorShare
        #expect(abs(proRAW - expected) < 0.01, "measured, not authored")
        #expect(proRAW < authored, "and stronger than the authored point")

        // However bright the file, the share keeps the anchor under the authored
        // point — that constant is the ceiling of the rule, because the knees were
        // authored for Apple Log 2's curve. (A 500 lifted ceiling still lands at
        // 500 x share; it takes a ceiling above authored / share to hit the cap.)
        let brighter = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 3.99,
                                                                      headroom: 5_000)
        #expect(abs(brighter - authored) < 0.01, "the authored point is the cap")
        #expect(brighter <= authored)
    }

    @Test func aNonFiniteMeasurementFallsBackToTheAuthoredReference() {
        let authored = 8 * Self.lift(1.1)
        let reference = SpatialEffectsStage.halationReferenceSuperwhite(sceneLiftStops: 1.1,
                                                                        headroom: .nan)
        #expect(abs(reference - authored) < 0.01, "garbage in must not move the anchor")
    }
}
