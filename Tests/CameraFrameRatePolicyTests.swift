import Foundation
import Testing
import CoreMedia

/// Session-only frame-rate mode and its transition gate. Mirrors
/// `CameraStabilizationPolicy.canChange`.
struct CameraFrameRatePolicyTests {
    private enum TransitionError: Error, Equatable { case format, exposure }

    @Test(arguments: [false, true])
    func failedFormatOrExposureRestoresPreviousMode(exposureFails: Bool) {
        var mode = CameraFrameRate.standard24
        var rollbackCount = 0
        var exposureApplied = false
        do {
            try CameraFrameRatePolicy.applyTransition(format: {
                mode = .daylight60
                if !exposureFails { throw TransitionError.format }
            }, exposure: {
                exposureApplied = true
                throw TransitionError.exposure
            }, rollback: {
                mode = .standard24
                rollbackCount += 1
            })
            Issue.record("A failed transition must not return success")
        } catch {
            #expect(error as? TransitionError == (exposureFails ? .exposure : .format))
        }
        #expect(mode == .standard24)
        #expect(rollbackCount == 1)
        #expect(exposureApplied == exposureFails)
    }

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

    @Test func boundaryResetsImmediatelyOnlyWhenNoTakeIsPendingActiveOrDraining() {
        #expect(CameraFrameRatePolicy.resetAction(recording: false, starting: false, finishing: false)
                == .resetImmediately)
        #expect(CameraFrameRatePolicy.resetAction(recording: true, starting: false, finishing: false)
                == .deferUntilTakeFinishes)
        #expect(CameraFrameRatePolicy.resetAction(recording: false, starting: true, finishing: false)
                == .deferUntilTakeFinishes)
        #expect(CameraFrameRatePolicy.resetAction(recording: false, starting: false, finishing: true)
                == .deferUntilTakeFinishes)
        #expect(CameraFrameRatePolicy.resetAction(recording: true, starting: true, finishing: true)
                == .deferUntilTakeFinishes)
    }
}

/// The per-URL capture-policy association. It is what the screen and the
/// awaiting-stock path read, so a session-boundary reset cannot mislabel a job.
struct DaylightCapturePolicyLedgerTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).mov") }

    @Test func recordsThePolicyCapturedAtTakeStartPerURL() {
        var ledger = DaylightCapturePolicyLedger()
        ledger.record(sourceURL: url("a"), mode: .daylight60)
        #expect(ledger.policy(for: url("a")) == RenderCapturePolicy(60))
        #expect(ledger.policy(for: url("missing")) == nil)
    }

    @Test func aLaterTakeDoesNotCorruptAnEarlierTakesMapping() {
        var ledger = DaylightCapturePolicyLedger()
        ledger.record(sourceURL: url("a"), mode: .daylight60)
        ledger.record(sourceURL: url("b"), mode: .standard24)
        #expect(ledger.policy(for: url("a")) == RenderCapturePolicy(60))
        #expect(ledger.policy(for: url("b")) == RenderCapturePolicy(24))
    }

    @Test func standardTwentyFourStillCarriesAnExplicitPolicy() {
        var ledger = DaylightCapturePolicyLedger()
        ledger.record(sourceURL: url("a"), mode: .standard24)
        #expect(ledger.policy(for: url("a")) == RenderCapturePolicy(24))
    }

    @Test func theLedgerIsBoundedAndKeepsTheMostRecentTakes() {
        var ledger = DaylightCapturePolicyLedger(limit: 2)
        for index in 0..<4 {
            ledger.record(sourceURL: url("take-\(index)"), mode: index.isMultiple(of: 2) ? .daylight60 : .standard24)
        }
        #expect(ledger.policies.count == 2)
        #expect(ledger.policy(for: url("take-3")) == RenderCapturePolicy(24))
        #expect(ledger.policy(for: url("take-2")) == RenderCapturePolicy(60))
        #expect(ledger.policy(for: url("take-0")) == nil)
    }

    @Test func clearDropsEveryMemory() {
        var ledger = DaylightCapturePolicyLedger()
        ledger.record(sourceURL: url("a"), mode: .daylight60)
        ledger.clear()
        #expect(ledger.policy(for: url("a")) == nil)
        #expect(ledger.policies.isEmpty)
    }

    @Test func leavingPhotoHandsTheIdleGraphTheFrameRateShutter() {
        let at24 = VideoExposureContract.idle(frameRate: .standard24, isManualExposure: false,
                                              manualISO: 400, bias: -1.2)
        #expect(abs(at24.durationSeconds - 1.0 / 48.0) < 1e-9)
        #expect(at24.lockedISO == nil, "Video meters ISO unless the operator holds one")
        #expect(at24.exposureBias == -1.2)

        let at60 = VideoExposureContract.idle(frameRate: .daylight60, isManualExposure: false,
                                              manualISO: 400, bias: 0)
        #expect(abs(at60.durationSeconds - 1.0 / 120.0) < 1e-9)
    }

    @Test func aHeldManualISOComesBackWithTheContract() {
        let manual = VideoExposureContract.idle(frameRate: .standard24, isManualExposure: true,
                                                manualISO: 800, bias: 0)
        #expect(manual.lockedISO == 800)
        #expect(abs(manual.durationSeconds - 1.0 / 48.0) < 1e-9)
    }
}
