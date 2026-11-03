import Foundation
import Testing

/// Contract for the Photo exposure the app runs when the operator holds an
/// aperture with the ISO left on auto.
///
/// The aperture is a hardware change to the amount of light reaching the sensor,
/// so a write that re-uses the gain read before the iris moved leaves the meter
/// at the aperture delta — the reported "f/4.0 reads -3.4 EV and never comes
/// back". Resolving from the baseline instead of the installed ISO also keeps a
/// second aperture move from compounding the first correction.
struct PhotoApertureExposureTests {
    private let rearISO: ClosedRange<Float> = 34...3200

    private func resolution(baselineISO: Float, baselineAperture: Float, ev: Float,
                            aperture: Float, isoRange: ClosedRange<Float>? = nil)
        -> PhotoApertureResolution? {
        PhotoApertureExposurePolicy.resolveISO(
            baseline: PhotoApertureBaseline(iso: baselineISO, aperture: baselineAperture, ev: ev),
            aperture: aperture, ev: ev, isoRange: isoRange ?? rearISO)
    }

    /// Opening the iris by two stops gives four times the light, so the gain
    /// must quarter to stay on target.
    @Test func openingTheApertureQuartersTheISOToHoldTheTarget() throws {
        let result = try #require(resolution(baselineISO: 400, baselineAperture: 8.0,
                                            ev: 0, aperture: 4.0))
        #expect(abs(result.iso - 100) <= 1, "f/8 -> f/4 is 2 EV more light; ISO must follow")
        #expect(!result.targetLimited)
        #expect(abs(result.achievedEV) <= 0.01)
        #expect(result.iso != 400, "the pre-change reading must not be re-written")
    }

    /// The reported field case: 0 EV metered wide open, then the iris is closed
    /// to f/4. The gain has to rise or the meter parks several stops dark.
    @Test func closingTheApertureRaisesISOToHoldTheTarget() throws {
        let result = try #require(resolution(baselineISO: 200, baselineAperture: 2.0,
                                            ev: 0, aperture: 4.0))
        #expect(abs(result.iso - 800) <= 1)
        #expect(!result.targetLimited)
        #expect(abs(result.achievedEV) <= 0.01)
    }

    /// A later EV change is a gain change from the same baseline, so the
    /// aperture correction is not applied twice.
    @Test func evChangeScalesFromTheBaselineWithoutReapplyingTheAperture() throws {
        let result = try #require(PhotoApertureExposurePolicy.resolveISO(
            baseline: PhotoApertureBaseline(iso: 400, aperture: 4.0, ev: 0),
            aperture: 4.0, ev: 1, isoRange: rearISO))
        #expect(abs(result.iso - 800) <= 1)
        #expect(abs(result.achievedEV - 1) <= 0.01)
    }

    /// Returning to the aperture the baseline was metered at returns the
    /// baseline gain exactly — successive moves must not compound.
    @Test func returningToTheBaselineApertureRestoresTheBaselineISO() throws {
        let baseline = PhotoApertureBaseline(iso: 400, aperture: 8.0, ev: 0)
        let opened = try #require(PhotoApertureExposurePolicy.resolveISO(
            baseline: baseline, aperture: 4.0, ev: 0, isoRange: rearISO))
        let returned = try #require(PhotoApertureExposurePolicy.resolveISO(
            baseline: baseline, aperture: 8.0, ev: 0, isoRange: rearISO))
        #expect(returned.iso == 400)
        #expect(opened.iso == 100)
    }

    /// The honest path: a target the ISO range cannot reach is reported as
    /// limited, with the compensation actually achieved, instead of silently
    /// sitting several stops off the target.
    @Test func unreachableTargetIsReportedInsteadOfClaimingTheTarget() throws {
        // f/2 -> f/11 costs 4.9 EV; 1600 * 30.25 is far past the format's 3200.
        let result = try #require(resolution(baselineISO: 1600, baselineAperture: 2.0,
                                            ev: 0, aperture: 11.0))
        #expect(result.iso == 3200)
        #expect(result.targetLimited)
        #expect(result.achievedEV < -3, "the shortfall must be visible, not rounded to the target")
    }

    @Test func unusableInputsResolveToNil() {
        #expect(resolution(baselineISO: .nan, baselineAperture: 2.0, ev: 0, aperture: 4.0) == nil)
        #expect(resolution(baselineISO: 100, baselineAperture: 0, ev: 0, aperture: 4.0) == nil)
        #expect(resolution(baselineISO: 100, baselineAperture: 2.0, ev: .nan, aperture: 4.0) == nil)
        #expect(resolution(baselineISO: 100, baselineAperture: 2.0, ev: 0, aperture: 0) == nil)
        #expect(resolution(baselineISO: 100, baselineAperture: 2.0, ev: 0, aperture: 4.0,
                           isoRange: 0...3200) == nil)
    }
}
