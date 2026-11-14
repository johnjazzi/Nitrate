import CoreMedia
import Foundation
import Testing

struct VideoPreviewExposureRegressionTests {
    @Test(arguments: CameraFrameRate.allCases)
    func videoPreviewUsesTheTakes180DegreeShutter(mode: CameraFrameRate) {
        let preview = VideoExposureContract.idle(frameRate: mode, isManualExposure: false,
                                                manualISO: 400, bias: -1.4)
        #expect(preview.durationSeconds == mode.filmShutterDuration.seconds)
        #expect(preview.lockedISO == nil)
        #expect(preview.exposureBias == -1.4)
    }

    @Test func meteredISOIsConvertedBeforeTheFilmShutterIsApplied() throws {
        let iso = try #require(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 800, meteredDuration: 1.0 / 480, targetDuration: 1.0 / 48,
            meteredOffsetEV: 0, targetEV: 0, minimum: 55, maximum: 5000))
        let expected = Float(800 * (1.0 / 480) / (1.0 / 48))
        #expect(abs(iso - expected) < 0.001)
    }

    @Test func saturationClampsOnlyAfterShutterAndBiasCorrection() {
        let iso = ExposureStabilizer.shutterMatchedISO(
            meteredISO: 800, meteredDuration: 1.0 / 6, targetDuration: 1.0 / 48,
            meteredOffsetEV: 0, targetEV: 0, minimum: 55, maximum: 5000)
        #expect(iso == 5000)
        let bright = ExposureStabilizer.shutterMatchedISO(
            meteredISO: 55, meteredDuration: 1.0 / 1000, targetDuration: 1.0 / 48,
            meteredOffsetEV: 0, targetEV: -1.4, minimum: 55, maximum: 5000)
        #expect(bright == 55)
    }

    @Test func neutralMeterOffsetPreventsApplyingTheHardwareBiasTwice() throws {
        let iso = try #require(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 800, meteredDuration: 1.0 / 480, targetDuration: 1.0 / 48,
            meteredOffsetEV: -1, targetEV: -1, minimum: 55, maximum: 5000))
        let expected = Float(800 * (1.0 / 480) / (1.0 / 48))
        #expect(abs(iso - expected) < 0.001)
    }

    @Test func switchingFromAutoISOToAnEqualNumericISOStillRequiresAWrite() {
        #expect(PhotoExposureCadence.needsWrite(iso: 200, duration: 1.0 / 48,
            actualISO: 200, actualDuration: 1.0 / 48, actualISOIsAutomatic: true))
        #expect(!PhotoExposureCadence.needsWrite(iso: 200, duration: 1.0 / 48,
            actualISO: 200, actualDuration: 1.0 / 48, actualISOIsAutomatic: false))
    }

    @Test func invalidDurationCannotProduceARecordingExposure() {
        for invalid in [0, -1, Double.nan, Double.infinity] {
            #expect(ExposureStabilizer.shutterMatchedISO(
                meteredISO: 800, meteredDuration: invalid, targetDuration: 1.0 / 48,
                meteredOffsetEV: 0, targetEV: 0, minimum: 55, maximum: 5000) == nil)
            #expect(ExposureStabilizer.shutterMatchedISO(
                meteredISO: 800, meteredDuration: 1.0 / 480, targetDuration: invalid,
                meteredOffsetEV: 0, targetEV: 0, minimum: 55, maximum: 5000) == nil)
        }
    }

    @Test func videoBiasRetargetStillUpdatesTheSharedPhotoPreference() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/CameraSession.swift"), encoding: .utf8)
        let mirror = try #require(source.components(separatedBy: "private func mirrorSharedExposureIntent()").last)
            .components(separatedBy: "private func sharedRecordingISO")[0]
        #expect(mirror.contains("controller.setEV(exposureBiasEV)"),
                "Changing Video's shared EV must not leave Photo with the old compensation.")
    }

    @Test func manualVideoPreviewDoesNotWaitForPhotosAutomaticMeterTarget() throws {
        let source = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/DevelopmentPhotoController.swift"), encoding: .utf8)
        let settling = try #require(source.components(separatedBy: "private var settling: Bool").last)
            .components(separatedBy: "private struct VideoExposurePlan")[0]
        #expect(settling.contains("return videoPreview.manualISO == nil"),
                "A fixed Video ISO/shutter does not autonomously settle toward Photo's EV.")
    }

    @Test(arguments: CameraFrameRate.allCases)
    func videoNeverInheritsThePhotoShutter(mode: CameraFrameRate) {
        let preview = VideoExposureContract.idle(frameRate: mode, isManualExposure: true,
                                                manualISO: 200, bias: -1.4, heldDuration: 1.0 / 1000)
        #expect(preview.durationSeconds == mode.filmShutterDuration.seconds)
        #expect(preview.lockedISO == 200)
    }
}
