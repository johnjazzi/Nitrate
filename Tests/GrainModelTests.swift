import Foundation
import Testing

/// Pure-math cover for the grain model: the ISO loudness law, the print-gauge
/// size/amplitude axis, the footprint floor, and the separation between the two
/// axes. These run without a Metal GPU; the GPU-level checks live in
/// `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    @Test func isoLoudnessIsSublinearAndMatchesTheMeasuredAnchor() {
        // Reference: ISO 50 → 1.0. σD ∝ ISO^0.46, so 50→500 is ~2.9×, not 10×.
        #expect(abs(GrainModel.isoLoudness(iso: 50) - 1.0) < tolerance)
        let ratio50to500 = GrainModel.isoLoudness(iso: 500) / GrainModel.isoLoudness(iso: 50)
        #expect(abs(ratio50to500 - 2.9) < 0.15,
                "50→500 loudness ratio should be ~2.9: \(ratio50to500)")
        // Two more measured steps.
        let ratio50to100 = GrainModel.isoLoudness(iso: 100) / GrainModel.isoLoudness(iso: 50)
        let ratio50to250 = GrainModel.isoLoudness(iso: 250) / GrainModel.isoLoudness(iso: 50)
        #expect(abs(ratio50to100 - 1.376) < 0.02, "50→100 ratio: \(ratio50to100)")
        #expect(abs(ratio50to250 - 2.096) < 0.02, "50→250 ratio: \(ratio50to250)")
        // Strictly increasing but sublinear across at least three steps.
        let steps: [Float] = [50, 100, 250, 500]
        let loudness = steps.map { GrainModel.isoLoudness(iso: $0) }
        for index in 1..<loudness.count {
            #expect(loudness[index] > loudness[index - 1], "loudness must increase with ISO")
            let loudnessRatio = loudness[index] / loudness[index - 1]
            let isoRatio = steps[index] / steps[index - 1]
            #expect(loudnessRatio < isoRatio,
                    "loudness must grow slower than ISO: \(loudnessRatio) vs \(isoRatio)")
        }
    }

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
    }

    @Test func gaugeAmplitudeAxisMakes75mmQuieterThan35mm() {
        #expect(PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
                < PrintGauge.thirtyFiveMillimetre.amplitudeMultiplier)
        let quiet = GrainModel.amount(iso: 500, gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.amount(iso: 500, gauge: .thirtyFiveMillimetre)
        #expect(quiet < neutral, "75mm must be quieter than 35mm at fixed ISO")
        // "Effectively grain-free" is delivered by amplitude, not by size.
        #expect(abs(quiet / neutral - 0.15) < tolerance,
                "75mm/35mm realized amplitude should be the 0.15 multiplier")
    }

    @Test func axesAreIndependent() {
        // The gauge must not change the ISO loudness term.
        for iso: Float in [50, 200, 500] {
            let reference = GrainModel.isoLoudness(iso: iso)
            for gauge in PrintGauge.allCases {
                #expect(abs(GrainModel.amount(iso: iso, gauge: gauge) / gauge.amplitudeMultiplier - reference) < tolerance,
                        "gauge must not alter ISO loudness (iso \(iso), gauge \(gauge))")
            }
        }
        // ISO must not change the footprint.
        let stock: Float = 1.15
        let baseline = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre)
        #expect(abs(baseline - stock) < tolerance)
    }

    @Test func footprintFloorKeepsTheVolumeOutOfTheUndersampledRegime() {
        // Finest gauge × smallest stock: 0.5 × 0.55 = 0.275 → floored to 0.95.
        let extreme = GrainModel.effectiveSize(stockGrainSize: 0.5, gauge: .seventyFiveMillimetre)
        #expect(extreme >= GrainModel.footprintFloor,
                "no combination may reach the undersampled regime: \(extreme)")
        #expect(abs(extreme - GrainModel.footprintFloor) < tolerance)
        // The shipped 75mm case: 1.3 × 0.55 = 0.715 → floored to 0.95.
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 1.3, gauge: .seventyFiveMillimetre) - 0.95) < tolerance)
        // Ceiling holds for a coarse gauge on a large stock.
        #expect(GrainModel.effectiveSize(stockGrainSize: 8, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }
}
