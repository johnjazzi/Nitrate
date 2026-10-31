import Foundation
import Testing

/// Pure-math cover for the grain model: the print gauge owns grain size AND
/// presence (amplitude); ISO is the exposure index and does not scale grain.
/// These run without a Metal GPU; the GPU-level checks live in `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    @Test func gaugeSizeAxisIsMonotonicAnd35mmIsTheDefault() {
        // Nominal multipliers are strictly monotonic across the ladder.
        let multipliers = PrintGauge.allCases.sorted { $0.sizeMultiplier < $1.sizeMultiplier }
            .map(\.sizeMultiplier)
        #expect(multipliers == [0.5, 0.9, 1.35, 2.0], "unexpected ladder: \(multipliers)")
        // 35mm is the middle of the ladder and the render default.
        #expect(PrintGauge.neutral == .thirtyFiveMillimetre)
        // Effective footprints are ordered across the whole ladder.
        let stock: Float = 1.3
        let fine = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre)
        let medium = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .sixteenMillimetre)
        let coarse = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .eightMillimetre)
        #expect(fine < neutral && neutral < medium && medium < coarse,
                "footprint must grow 75mm < 35mm < 16mm < 8mm: \(fine), \(neutral), \(medium), \(coarse)")
        #expect(coarse >= neutral * 2, "8mm should be a real step up: \(neutral) -> \(coarse)")
    }

    @Test func gaugeOwnsPresenceAcrossTheLadder() {
        let ladder: [PrintGauge] = [.eightMillimetre, .sixteenMillimetre,
                                    .thirtyFiveMillimetre, .seventyFiveMillimetre]
        let amounts = ladder.map { GrainModel.amount(gauge: $0) }
        // Presence falls strictly from the coarsest rung to the finest.
        #expect(zip(amounts, amounts.dropFirst()).allSatisfy { $0 > $1 },
                "presence must fall toward the fine end: \(amounts)")
        // Realized amount is baseAmount times the gauge's presence multiplier.
        for (index, gauge) in ladder.enumerated() {
            let expected = GrainModel.baseAmount * gauge.amplitudeMultiplier
            #expect(abs(amounts[index] - expected) < tolerance)
        }
    }

    @Test func everyStockAndGaugeUsesHalfThePreviousSizeAndTenPercentMorePresence() throws {
        let gauges: [(PrintGauge, Float, Float)] = [
            (.eightMillimetre, 4.0, 0.50), (.sixteenMillimetre, 2.7, 0.36),
            (.thirtyFiveMillimetre, 1.8, 0.27), (.seventyFiveMillimetre, 1.0, 0.15)
        ]
        #expect(abs(GrainModel.baseAmount - 0.55 * 1.10) < tolerance)
        #expect(GrainModel.footprintFloor == 0.475)
        #expect(GrainModel.footprintCeiling == 8.0)
        // Both shipped stock sizes, plus values exercising the old clamp bounds.
        for stockSize: Float in [0.1, 0.5, 1.15, 1.3, 12, 100] {
            for (gauge, previousSizeMultiplier, previousAmplitude) in gauges {
                let previousFootprint = min(max(stockSize * previousSizeMultiplier, 0.95), 16.0)
                let footprint = GrainModel.effectiveSize(stockGrainSize: stockSize, gauge: gauge)
                #expect(abs(footprint - previousFootprint * 0.5) < tolerance)
                #expect(gauge.amplitudeMultiplier == previousAmplitude)
                for edgeFactor: Float in [1, 3, 4] {
                    let previousAmount = 0.55 * previousAmplitude * edgeFactor
                    #expect(abs(GrainModel.amount(gauge: gauge, edgeFactor: edgeFactor)
                                - previousAmount * 1.10) < tolerance)
                }
            }
        }
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

    @Test func footprintBoundsAllowRequestedSubpixelGrainAndClampExtremes() {
        // Finest gauge x small stock: 0.5 x 0.5 = 0.25 -> bounded at 0.475.
        let extreme = GrainModel.effectiveSize(stockGrainSize: 0.5, gauge: .seventyFiveMillimetre)
        #expect(extreme >= GrainModel.footprintFloor,
                "no combination may fall below the requested lower bound: \(extreme)")
        #expect(abs(extreme - GrainModel.footprintFloor) < tolerance)
        // The requested subpixel floor is a bound, not an anti-aliasing guarantee.
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 0.7, gauge: .seventyFiveMillimetre) - 0.475) < tolerance)
        // Ceiling holds for the coarsest gauge on a large stock.
        #expect(GrainModel.effectiveSize(stockGrainSize: 12, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }
}
