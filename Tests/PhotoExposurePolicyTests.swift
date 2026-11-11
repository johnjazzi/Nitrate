import Foundation
import Testing

struct PhotoExposurePolicyTests {
    @Test func slowShutterSuspendsOnlyPreviewNotCapture() {
        for duration in [0.25, 0.5, 1.0] {
            #expect(PhotoExposurePolicy.shouldSuspendPreview(durationSeconds: duration))
            #expect(PhotoExposurePolicy.captureAvailable(started: true, stopped: false, capturing: false))
        }
        for duration in [0.0, 1.0 / 60, 1.0 / 8, .nan, .infinity] {
            #expect(!PhotoExposurePolicy.shouldSuspendPreview(durationSeconds: duration))
        }
    }

    @Test func captureIsNotBlockedByAnUnmetMeterTarget() {
        #expect(PhotoExposurePolicy.captureAvailable(started: true, stopped: false, capturing: false))
        #expect(!PhotoExposurePolicy.captureAvailable(started: true, stopped: true, capturing: false))
        #expect(!PhotoExposurePolicy.captureAvailable(started: true, stopped: false, capturing: true))
    }
    private func snapshot(iso: Float = 200,
                         duration: Double = 1.0 / 60.0,
                         isoLocked: Bool,
                         shutterLocked: Bool,
                         isoRange: ClosedRange<Float> = 50...800,
                         shutterRange: ClosedRange<Double> = 1.0 / 8000.0...1.0) -> PhotoExposureSnapshot {
        PhotoExposureSnapshot(iso: iso,
                              durationSeconds: duration,
                              isoRange: isoRange,
                              shutterRange: shutterRange,
                              isoLocked: isoLocked,
                              shutterLocked: shutterLocked,
                              ev: 0,
                              meteringOffset: 0,
                              isSettling: false,
                              canCapture: true,
                              targetLimited: false)
    }

    private func request(ev: Float = 1, measuredEV: Float = 0, maxCorrectionEV: Float = 2)
        -> PhotoExposureRequest {
        PhotoExposureRequest(ev: ev, measuredEV: measuredEV, maxCorrectionEV: maxCorrectionEV)
    }

    @Test func floatingISOOnlyReceivesEVCorrectionWhenShutterIsLocked() throws {
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: true),
                                                    request: request())
        #expect(result.iso != nil)
        #expect(result.iso == 400)
        #expect(result.durationSeconds == nil)
    }

    @Test func floatingShutterOnlyReceivesEVCorrectionWhenISOIsLocked() throws {
        // A held ISO leaves the shutter free at any ISO, not only at the
        // camera's extremes.
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(iso: 800, isoLocked: true,
                                                                      shutterLocked: false),
                                                    request: request())
        #expect(result.iso == nil)
        #expect(result.durationSeconds != nil)
        #expect(abs((result.durationSeconds ?? 0) - 1.0 / 30.0) < 0.0000001)
    }

    @Test func fullyFloatingStateUsesNativeAutoExposure() throws {
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: false),
                                                    request: request())
        #expect(result.usesAutoExposure)
        #expect(result.iso == nil && result.durationSeconds == nil)
    }

    @Test func bothLockedIsMeterOnlyAndDoesNotMutateEitherValue() throws {
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: true, shutterLocked: true),
                                                    request: request())
        #expect(result.iso == nil)
        #expect(result.durationSeconds == nil)
        #expect(result.meteringOffset == -1)
        #expect(!result.isSettling)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonFiniteEVIsRejected(_ ev: Float) {
        #expect(throws: PhotoExposurePolicyError.nonFiniteInput) {
            _ = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: false),
                                               request: request(ev: ev))
        }
    }

    @Test func negativeCorrectionLimitIsRejected() {
        #expect(throws: PhotoExposurePolicyError.negativeCorrectionLimit) {
            _ = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: false),
                                               request: request(maxCorrectionEV: -0.1))
        }
    }

    @Test func unsupportedCurrentValueIsRejected() {
        #expect(throws: PhotoExposurePolicyError.valueOutOfRange) {
            _ = try PhotoExposurePolicy.decide(snapshot: snapshot(iso: 900, isoLocked: true, shutterLocked: true),
                                               request: request())
        }
    }

    @Test func aLargeMeteringErrorConvergesInAFewStepsNotOneQuarterStopAtATime() throws {
        // Shutter priority (ISO locked, shutter auto) three stops off: the old
        // 0.25 EV per-step cap needed 12 corrections to arrive, which is what
        // made the auto shutter feel sluggish.
        var duration = 1.0 / 60.0
        let iso: Float = 800
        var steps = 0
        while abs(log2((1.0 / 60.0) / duration)) < 2.9 && steps < 20 {
            let state = snapshot(iso: iso, duration: duration, isoLocked: true, shutterLocked: false)
            let decision = try PhotoExposurePolicy.decide(snapshot: state,
                request: request(ev: -3, measuredEV: 0, maxCorrectionEV: 0.25))
            guard let next = decision.durationSeconds else { break }
            duration = next
            steps += 1
        }
        #expect(steps <= 4, "3 EV must converge in at most 4 corrections, took \(steps)")
    }

    @Test func aNearTargetErrorStillDampsWithTheSmallStep() throws {
        let state = snapshot(iso: 800, duration: 1.0 / 60.0, isoLocked: true, shutterLocked: false)
        let decision = try PhotoExposurePolicy.decide(snapshot: state,
            request: request(ev: 0.2, measuredEV: 0, maxCorrectionEV: 0.25))
        let applied = try #require(decision.durationSeconds)
        let appliedEV = log2(applied / (1.0 / 60.0))
        #expect(abs(appliedEV - 0.2) < 0.001, "inside the near zone the step must stay exact and small")
    }

    @Test func aHeldISOFloatsTheShutterToReachTheCompensation() throws {
        // ISO held inside the normal band (200 of 50...800), frame metering 2 EV
        // over the target. The shutter is the metering's only lever, so it *raises*
        // instead of the operator's shutter being pinned at the film standard and
        // the frame staying blown. This is the "the shutter isn't raising when ev
        // is high" case: it used to return nil (no correction) and report
        // targetLimited, so a pinned ISO could never be met by the shutter.
        let state = snapshot(iso: 200, duration: 1.0 / 48.0, isoLocked: true, shutterLocked: false)
        let decision = try PhotoExposurePolicy.decide(snapshot: state,
            request: request(ev: 0, measuredEV: 2, maxCorrectionEV: 0.25))
        let floated = try #require(decision.durationSeconds)
        #expect(floated < 1.0 / 48.0, "a frame over the target must raise the shutter speed")
        #expect(abs(log2((1.0 / 48.0) / floated) - 1) < 0.001,
                "a far error moves one bounded 1 EV step, then converges")
        #expect(!decision.targetLimited)
    }

    @Test func aHeldShutterIsNeverFloatedByTheISO() throws {
        // The mirror case: the shutter rail holds the shutter, so the ISO is the
        // only thing the metering may move — and it never touches the shutter.
        let state = snapshot(iso: 200, duration: 1.0 / 48.0, isoLocked: false, shutterLocked: true)
        let decision = try PhotoExposurePolicy.decide(snapshot: state, request: request(ev: 1))
        #expect(decision.durationSeconds == nil)
        #expect(decision.iso == 400)
    }

    @Test func floatingShutterNeverGoesSlowerThanOneSixteenth() throws {
        let state = snapshot(iso: 800, duration: 1.0 / 30.0, isoLocked: true, shutterLocked: false)
        let decision = try PhotoExposurePolicy.decide(snapshot: state,
            request: request(ev: 6, maxCorrectionEV: 6))
        let floated = try #require(decision.durationSeconds)
        #expect(abs(floated - PhotoShutterFloatPolicy.floorSeconds) < 0.000001)
        #expect(decision.targetLimited)
    }

    @Test func floatNeverPushesAManualShutterPastTheOperatorsChoice() throws {
        // The operator deliberately dragged 1/8s, slower than the 1/16s float
        // floor: the float may shorten that, never walk it out past 1/8s.
        let state = snapshot(iso: 800, duration: 1.0 / 8.0, isoLocked: true, shutterLocked: false)
        let decision = try PhotoExposurePolicy.decide(snapshot: state, request: request(ev: 1))
        let floated = try #require(decision.durationSeconds)
        #expect(abs(floated - 1.0 / 8.0) < 0.000001)
    }

    @Test func correctionIsBoundedAndReportsHardwareLimit() throws {
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(iso: 800,
                                                                      isoLocked: false,
                                                                      shutterLocked: true),
                                                    request: request(ev: 4, maxCorrectionEV: 0.5))
        #expect(result.iso == 800)
        #expect(result.targetLimited)
    }

    @Test func decisionReportsSettlingUntilExposureConverges() throws {
        let result = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: true),
                                                    request: request())
        #expect(result.isSettling)
        let converged = try PhotoExposurePolicy.decide(snapshot: snapshot(isoLocked: false, shutterLocked: true),
                                                       request: request(ev: 0, measuredEV: 0))
        #expect(!converged.isSettling)
        #expect(converged.iso == nil && converged.durationSeconds == nil)
    }
}
