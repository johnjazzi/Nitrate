import Testing

/// The measured exposure meter's second index: the render's position on the
/// same EV scale as the scene it was metered from.
struct ExposureRenderMarkerTests {
    @Test func neutralDevelopmentMarksNothing() {
        #expect(ExposureRenderMarker(pushPull: .neutral, meteredEV: 1.2) == nil)
        #expect(ExposureRenderMarker(pushPull: .automatic(meteredOffsetEV: 0.2), meteredEV: 0.2) == nil)
    }

    @Test func noStockMarksNothing() {
        #expect(ExposureRenderMarker(pushPull: nil, meteredEV: 1.2) == nil)
    }

    @Test func missingOrInvalidMeterCannotInventAPosition() {
        #expect(ExposureRenderMarker(pushPull: .manual(.pullOne), meteredEV: nil) == nil)
        #expect(ExposureRenderMarker(pushPull: .manual(.pullOne), meteredEV: .nan) == nil)
        #expect(ExposureRenderMarker(pushPull: .manual(.pullOne), meteredEV: .infinity) == nil)
    }

    @Test func aPullMarksTheRenderBelowTheMeterAndAPushAbove() {
        let pulled = ExposureRenderMarker(pushPull: .manual(.pullTwo), meteredEV: 1.6)
        #expect(abs((pulled?.renderedEV ?? .nan) - (-0.4)) < 1e-5)
        #expect(pulled?.text == "-2")
        let pushed = ExposureRenderMarker(pushPull: .manual(.pushOne), meteredEV: 1.6)
        #expect(abs((pushed?.renderedEV ?? .nan) - 2.6) < 1e-5)
        #expect(pushed?.text == "+1")
    }

    @Test func markIsPlacedOnTheMetersOwnScale() throws {
        // The meter spans ±2 EV; the mark is placed with the same policy as the
        // measured pointer. +1 EV meters at 0.75, so a +1 stop render clamps at
        // the right edge and a -1 stop lands back on centre.
        let pushed = try #require(ExposureRenderMarker(pushPull: .manual(.pushOne), meteredEV: 1))
        let pulled = try #require(ExposureRenderMarker(pushPull: .manual(.pullOne), meteredEV: 1))
        #expect(ExposureIndicatorPolicy.position(ev: pushed.renderedEV) == 1)
        #expect(ExposureIndicatorPolicy.position(ev: pulled.renderedEV) == 0.5)
    }

    @Test func spokenDescriptionNamesTheShiftAndItsDirection() {
        let pulled = ExposureRenderMarker(pushPull: .manual(.pullTwo), meteredEV: 1.6)
        #expect(pulled?.spokenDescription == "render -0.40 EV after pulling 2 stops")
        let pushed = ExposureRenderMarker(pushPull: .manual(.pushOne), meteredEV: 1.6)
        #expect(pushed?.spokenDescription == "render +2.60 EV after pushing 1 stop")
    }
}
