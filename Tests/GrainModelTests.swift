import Foundation
import Testing

/// Pure-math cover for the grain model: the print gauge owns grain size AND
/// presence (amplitude); ISO is the exposure index and does not scale grain.
/// These run without a Metal GPU; the GPU-level checks live in `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    @Test func gaugeSizeAxisIsMonotonicAnd35mmIsNeutral() {
        let stock: Float = 1.3
        let fine = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre)
        let medium = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .sixteenMillimetre)
        let coarse = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .eightMillimetre)
        #expect(fine < neutral && neutral < medium && medium < coarse,
                "footprint must grow 75mm < 35mm < 16mm < 8mm: \(fine), \(neutral), \(medium), \(coarse)")
        #expect(abs(PrintGauge.thirtyFiveMillimetre.sizeMultiplier - 1.0) < tolerance)
        #expect(abs(PrintGauge.thirtyFiveMillimetre.amplitudeMultiplier - 1.0) < tolerance)
        // The coarse gauge must be genuinely coarser, not a token step: 8mm is
        // 3x the neutral footprint after the debug-mode retune.
        #expect(coarse >= neutral * 2.5,
                "8mm footprint should be a real step up from 35mm: \(neutral) -> \(coarse)")
    }

    @Test func gaugeOwnsPresenceAnd75mmIsNearlySilent() {
        #expect(PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
                < PrintGauge.thirtyFiveMillimetre.amplitudeMultiplier)
        let quiet = GrainModel.amount(gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.amount(gauge: .thirtyFiveMillimetre)
        let coarse = GrainModel.amount(gauge: .eightMillimetre)
        #expect(quiet < neutral, "75mm must be quieter than 35mm")
        #expect(coarse > neutral, "8mm must be more present than 35mm")
        // "Effectively grain-free" is delivered by amplitude, not by size.
        #expect(abs(quiet / neutral - 0.15) < tolerance,
                "75mm/35mm realized amplitude should be the 0.15 multiplier")
    }

    @Test func isoDoesNotScaleGrain() {
        // Presence depends only on the gauge and baseAmount; there is no ISO term.
        let neutral = GrainModel.amount(gauge: .thirtyFiveMillimetre)
        let coarse = GrainModel.amount(gauge: .eightMillimetre)
        #expect(abs(neutral - GrainModel.baseAmount) < tolerance)
        #expect(abs(coarse - GrainModel.baseAmount * PrintGauge.eightMillimetre.amplitudeMultiplier) < tolerance)
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
        #expect(GrainModel.effectiveSize(stockGrainSize: 8, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }
}
