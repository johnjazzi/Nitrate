import Foundation
import Testing

/// Pure-math cover for the grain model: the print gauge owns grain size AND
/// presence (amplitude); ISO is the exposure index and does not scale grain.
/// These run without a Metal GPU; the GPU-level checks live in `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    @Test func gaugeSizeAxisIsMonotonicAnd35mmIsTheReference() {
        // Nominal multipliers are strictly monotonic across the ladder.
        let multipliers = PrintGauge.allCases.sorted { $0.sizeMultiplier < $1.sizeMultiplier }
            .map(\.sizeMultiplier)
        #expect(multipliers == [0.55, 1.0, 1.8, 3.0], "unexpected ladder: \(multipliers)")
        // 35mm carries the stock's authored size and is the reference.
        #expect(abs(PrintGauge.thirtyFiveMillimetre.sizeMultiplier - 1.0) < tolerance)
        #expect(PrintGauge.neutral == .thirtyFiveMillimetre)
        // Effective footprints are ordered across the whole ladder.
        let stock: Float = 1.3
        let fine = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre)
        let medium = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .sixteenMillimetre)
        let coarse = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .eightMillimetre)
        #expect(fine < neutral && neutral < medium && medium < coarse,
                "footprint must grow 75mm < 35mm < 16mm < 8mm: \(fine), \(neutral), \(medium), \(coarse)")
        #expect(coarse >= neutral * 2.5, "8mm should be a real step up: \(neutral) -> \(coarse)")
    }

    @Test func gaugeOwnsPresenceAnd75mmIsExtremelySubtle() {
        let quiet = GrainModel.amount(gauge: .seventyFiveMillimetre)
        let reference = GrainModel.amount(gauge: .sixteenMillimetre)
        let coarse = GrainModel.amount(gauge: .eightMillimetre)
        #expect(quiet < reference, "75mm must be quieter than the 16mm reference")
        #expect(coarse > reference, "8mm must be more present than the 16mm reference")
        // Realized amplitude is the ratio of the two multipliers.
        let expected = PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
            / PrintGauge.sixteenMillimetre.amplitudeMultiplier
        #expect(abs(quiet / reference - expected) < tolerance)
        // "Extremely subtle" is delivered by amplitude, not by size.
        #expect(quiet / reference < 0.1, "75mm should be extremely subtle: \(quiet / reference)")
    }

    @Test func isoDoesNotScaleGrain() {
        // Presence depends only on the gauge and baseAmount; there is no ISO term.
        let reference = GrainModel.amount(gauge: .sixteenMillimetre)
        let coarse = GrainModel.amount(gauge: .eightMillimetre)
        #expect(abs(reference - GrainModel.baseAmount
                    * PrintGauge.sixteenMillimetre.amplitudeMultiplier) < tolerance)
        #expect(abs(coarse - GrainModel.baseAmount
                    * PrintGauge.eightMillimetre.amplitudeMultiplier) < tolerance)
    }

    @Test func footprintFloorKeepsTheVolumeOutOfTheUndersampledRegime() {
        // Finest gauge x smallest stock: 0.5 x 0.55 = 0.275 -> floored to 0.95.
        let extreme = GrainModel.effectiveSize(stockGrainSize: 0.5, gauge: .seventyFiveMillimetre)
        #expect(extreme >= GrainModel.footprintFloor,
                "no combination may reach the undersampled regime: \(extreme)")
        #expect(abs(extreme - GrainModel.footprintFloor) < tolerance)
        // The shipped 75mm case: 1.3 x 0.55 = 0.715 -> floored to 0.95.
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 1.3, gauge: .seventyFiveMillimetre) - 0.95) < tolerance)
        // Ceiling holds for the coarsest gauge on a large stock.
        #expect(GrainModel.effectiveSize(stockGrainSize: 12, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }
}
