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
        #expect(multipliers == [1.0, 1.8, 2.7, 4.0], "unexpected ladder: \(multipliers)")
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

    @Test func requestedGaugeTuningReducesOnlySixteenSizeAndSixteenAndThirtyFivePresence() {
        #expect(PrintGauge.sixteenMillimetre.sizeMultiplier == 2.7)
        #expect(PrintGauge.sixteenMillimetre.amplitudeMultiplier == 0.36)
        #expect(PrintGauge.thirtyFiveMillimetre.sizeMultiplier == 1.8)
        #expect(PrintGauge.thirtyFiveMillimetre.amplitudeMultiplier == 0.27)
        #expect(PrintGauge.eightMillimetre.sizeMultiplier == 4.0)
        #expect(PrintGauge.eightMillimetre.amplitudeMultiplier == 0.50)
        #expect(PrintGauge.seventyFiveMillimetre.sizeMultiplier == 1.0)
        #expect(PrintGauge.seventyFiveMillimetre.amplitudeMultiplier == 0.15)
        #expect(GrainModel.baseAmount == 0.55)
        #expect(GrainModel.footprintFloor == 0.95)
        #expect(GrainModel.footprintCeiling == 16.0)

        let stocks: [(size: Float, previousSixteen: Float, sixteen: Float,
                      thirtyFive: Float, eight: Float, seventyFive: Float)] = [
            (1.15, 3.45, 3.105, 2.07, 4.6, 1.15),
            (1.3, 3.9, 3.51, 2.34, 5.2, 1.3)
        ]
        for stock in stocks {
            let sixteen = GrainModel.effectiveSize(stockGrainSize: stock.size, gauge: .sixteenMillimetre)
            #expect(abs(sixteen - stock.sixteen) < tolerance)
            #expect(abs(sixteen - stock.previousSixteen * 0.9) < tolerance)
            let thirtyFive = GrainModel.effectiveSize(stockGrainSize: stock.size, gauge: .thirtyFiveMillimetre)
            #expect(abs(thirtyFive - stock.thirtyFive) < tolerance)
            let eight = GrainModel.effectiveSize(stockGrainSize: stock.size, gauge: .eightMillimetre)
            #expect(abs(eight - stock.eight) < tolerance)
            let seventyFive = GrainModel.effectiveSize(stockGrainSize: stock.size, gauge: .seventyFiveMillimetre)
            #expect(abs(seventyFive - stock.seventyFive) < tolerance)
        }

        for edgeFactor: Float in [1, 3] {
            let sixteen = GrainModel.amount(gauge: .sixteenMillimetre, edgeFactor: edgeFactor)
            let thirtyFive = GrainModel.amount(gauge: .thirtyFiveMillimetre, edgeFactor: edgeFactor)
            #expect(abs(sixteen - 0.2200 * 0.9 * edgeFactor) < tolerance)
            #expect(abs(thirtyFive - 0.1650 * 0.9 * edgeFactor) < tolerance)
            let eight = GrainModel.amount(gauge: .eightMillimetre, edgeFactor: edgeFactor)
            let seventyFive = GrainModel.amount(gauge: .seventyFiveMillimetre, edgeFactor: edgeFactor)
            #expect(abs(eight - 0.2750 * edgeFactor) < tolerance)
            #expect(abs(seventyFive - 0.0825 * edgeFactor) < tolerance)
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

    @Test func footprintFloorKeepsTheVolumeOutOfTheUndersampledRegime() {
        // Finest gauge x smallest stock: 0.5 x 0.55 = 0.275 -> floored to 0.95.
        let extreme = GrainModel.effectiveSize(stockGrainSize: 0.5, gauge: .seventyFiveMillimetre)
        #expect(extreme >= GrainModel.footprintFloor,
                "no combination may reach the undersampled regime: \(extreme)")
        #expect(abs(extreme - GrainModel.footprintFloor) < tolerance)
        // A finer stock still cannot reach the undersampled regime.
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 0.7, gauge: .seventyFiveMillimetre) - 0.95) < tolerance)
        // Ceiling holds for the coarsest gauge on a large stock.
        #expect(GrainModel.effectiveSize(stockGrainSize: 12, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }
}
