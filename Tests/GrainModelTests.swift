import Foundation
import Testing

/// Pure-math cover for the grain model: the print gauge owns grain size AND
/// presence (amplitude); ISO is the exposure index and does not scale grain.
/// These run without a Metal GPU; the GPU-level checks live in `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    @Test func gaugeSizeAxisIsMonotonicAnd16mmIsTheReference() {
        // Nominal multipliers are strictly monotonic across the ladder.
        let multipliers = PrintGauge.allCases.sorted { $0.sizeMultiplier < $1.sizeMultiplier }
            .map(\.sizeMultiplier)
        #expect(multipliers == [0.45, 0.55, 1.0, 1.8], "unexpected ladder: \(multipliers)")
        // The 16mm rung carries the stock's authored size and is the reference.
        #expect(abs(PrintGauge.sixteenMillimetre.sizeMultiplier - 1.0) < tolerance)
        #expect(PrintGauge.neutral == .sixteenMillimetre)
        // Effective footprints stay ordered from the reference upward. The two
        // finest rungs are both pinned by the sampling floor, which is intended:
        // they differ by presence, not by footprint.
        let stock: Float = 1.3
        let medium = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .sixteenMillimetre)
        let coarse = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .eightMillimetre)
        #expect(medium < coarse, "8mm must be coarser than the reference: \(medium) -> \(coarse)")
        #expect(coarse >= medium * 1.5, "8mm should be a real step up: \(medium) -> \(coarse)")
        #expect(GrainModel.effectiveSize(stockGrainSize: stock, gauge: .seventyFiveMillimetre)
                == GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre),
                "the two finest rungs are floored, so they share a footprint")
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
