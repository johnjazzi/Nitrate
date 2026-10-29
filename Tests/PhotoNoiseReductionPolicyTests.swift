import Foundation
import Testing

/// The still path develops raw Bayer data, so its noise is the sensor's own. These
/// tests pin the ramp that decides how much of it the decode removes, and the fact
/// that only colour is ever touched.
@Suite("Photo noise reduction policy")
struct PhotoNoiseReductionPolicyTests {
    @Test("a clean frame is left alone")
    func aCleanFrameIsLeftAlone() {
        for iso in [55, 80, 100, 199] {
            #expect(PhotoNoiseReductionPolicy.colorAmount(iso: iso) == 0, "ISO \(iso) needs no reduction")
        }
    }

    @Test("the first segment is linear in stops")
    func theFirstSegmentIsLinearInStops() {
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: 200) == 0)
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 400) - 0.32300) < 0.001)
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 640) - 0.54200) < 0.001)
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 800) - 0.64601) < 0.001)
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 1000) - 0.75) < 0.0001)
    }

    @Test("the second segment climbs from the shoulder to the control's maximum")
    func theSecondSegmentClimbsToTheControlMaximum() {
        // The plateau moves with sensitivity, so the ramp cannot stop at 1000: 0.75 is
        // where 1000 and 1600 saturate, while 12500 is still improving at 1.00.
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 1600) - 0.79652) < 0.001)
        #expect(abs(PhotoNoiseReductionPolicy.colorAmount(iso: 3200) - 0.86513) < 0.001)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: 12500) == 1.0)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: 25600) == 1.0)
    }

    @Test("no input produces a nonsense amount")
    func noInputProducesANonsenseAmount() {
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: nil) == 0)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: 0) == 0)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: -100) == 0)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: Float.infinity) == 0)
        #expect(PhotoNoiseReductionPolicy.colorAmount(iso: Float.nan) == 0)
        let ladder: [Float] = [55, 100, 200, 400, 640, 800, 1000, 1600, 3200, 6400, 12500, 51200]
        var previous: Float = 0
        for iso in ladder {
            let amount = PhotoNoiseReductionPolicy.colorAmount(iso: iso)
            #expect(amount.isFinite)
            #expect(amount >= 0 && amount <= PhotoNoiseReductionPolicy.maximumColorAmount)
            #expect(amount >= previous, "the ramp must never fall as sensitivity rises")
            previous = amount
        }
    }

    @Test("luma is never reduced")
    func lumaIsNeverReduced() {
        // Luma texture is the film look's substrate and the app adds its own grain;
        // lighting it down would fight the recipe rather than clean the sensor.
        for iso in [Float(100), 400, 1000, 6400, 12500] {
            #expect(PhotoNoiseReductionPolicy.luminanceAmount(iso: iso) == 0)
        }
    }

    @Test("the decode reports the amount it used")
    func theDecodeReportsTheAmountItUsed() {
        #expect(PhotoNoiseReductionPolicy.report(iso: 1000).hasPrefix("color=0.75"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 1000).contains("luminance=0"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 1000).contains("iso-ramped-to-1000"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 12500).hasPrefix("color=1.00"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 12500).contains("iso-ramped-to-12500"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 100).hasPrefix("color=0.00"))
        #expect(PhotoNoiseReductionPolicy.report(iso: 100).contains("iso-below-200"))
        #expect(PhotoNoiseReductionPolicy.report(iso: nil).hasPrefix("color=0.00"))
    }
}
