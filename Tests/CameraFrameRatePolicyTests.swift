import Foundation
import Testing
import CoreMedia

/// Session-only frame-rate mode and its transition gate. Mirrors
/// `CameraStabilizationPolicy.canChange`.
struct CameraFrameRatePolicyTests {
    @Test func changeIsRejectedWhileRecordingStartingOrFinishing() {
        #expect(!CameraFrameRatePolicy.canChange(recording: true, starting: false, finishing: false))
        #expect(!CameraFrameRatePolicy.canChange(recording: false, starting: true, finishing: false))
        #expect(!CameraFrameRatePolicy.canChange(recording: false, starting: false, finishing: true))
        #expect(!CameraFrameRatePolicy.canChange(recording: true, starting: true, finishing: true))
    }

    @Test func changeIsAllowedOnlyWhenNoTakeIsPendingActiveOrDraining() {
        #expect(CameraFrameRatePolicy.canChange(recording: false, starting: false, finishing: false))
    }

    @Test func shutterTracksTheModeAtOneEightyDegrees() {
        #expect(CameraFrameRate.standard24.shutterDenominator == 48)
        #expect(CameraFrameRate.daylight60.shutterDenominator == 120)
        #expect(CameraFrameRate.standard24.filmShutterDuration == CMTime(value: 1, timescale: 48))
        #expect(CameraFrameRate.daylight60.filmShutterDuration == CMTime(value: 1, timescale: 120))
    }

    @Test func frameDurationIsOneOverFps() {
        #expect(CameraFrameRate.standard24.frameDuration == CMTime(value: 1, timescale: 24))
        #expect(CameraFrameRate.daylight60.frameDuration == CMTime(value: 1, timescale: 60))
    }

    @Test func recorderFallbackDurationFollowsTheModeNeverGuessesTwentyFour() {
        #expect(CameraFrameRate.standard24.fallbackVideoSampleDuration == CMTime(value: 1, timescale: 24))
        #expect(CameraFrameRate.daylight60.fallbackVideoSampleDuration == CMTime(value: 1, timescale: 60))
    }

    @Test func wholeNumberFpsMapsToAModeOrNil() {
        #expect(CameraFrameRate.from(fps: 24) == .standard24)
        #expect(CameraFrameRate.from(fps: 60) == .daylight60)
        #expect(CameraFrameRate.from(fps: 30) == nil)
    }

    @Test func rawValuesAreTheFps() {
        #expect(CameraFrameRate.standard24.rawValue == 24)
        #expect(CameraFrameRate.daylight60.rawValue == 60)
        #expect(CameraFrameRate.daylight60.fps == 60)
    }
}
