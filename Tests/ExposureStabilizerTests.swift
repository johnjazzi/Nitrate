import Foundation
import Testing

/// Pure-policy coverage for the shutter-priority stabiliser and the under/over
/// exposure indicator. No AVCaptureDevice is constructed: the flicker fix and
/// the indicator mapping both live in `CameraPolicies.swift`.
@Suite("Exposure stabiliser and indicator")
struct ExposureStabilizerTests {
    // MARK: - Stabiliser: deadband

    @Test func holdsWhileTheMeterStaysInsideTheDeadband() {
        // Pinned at 800 (raw meter 400, +1 EV). A raw meter of 420 is a 0.07
        // stop move: the compensated target 840 is within a third of a stop of
        // the pin, so nothing is written and the preview does not step.
        let pin = ExposureStabilizer.Pin(iso: 800, ev: 1, meteredISO: 400)
        #expect(ExposureStabilizer.decide(meteredISO: 420, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .hold)
        // The raw meter unchanged is also held.
        #expect(ExposureStabilizer.decide(meteredISO: 400, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .hold)
    }

    @Test func reappliesOnceTheMeterMovesPastTheDeadband() {
        let pin = ExposureStabilizer.Pin(iso: 800, ev: 1, meteredISO: 400)
        // 400 -> 600 is ~0.58 stop: target 1200 is a real change.
        #expect(ExposureStabilizer.decide(meteredISO: 600, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .apply(iso: 1200))
        // 400 -> 260 (darker): target 520 is also past the deadband.
        #expect(ExposureStabilizer.decide(meteredISO: 260, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .apply(iso: 520))
    }

    @Test func firstReadingAppliesAndIsClampedToTheDeviceRange() {
        #expect(ExposureStabilizer.decide(meteredISO: 400, ev: 1, current: nil,
                                           minimum: 25, maximum: 6400) == .apply(iso: 800))
        #expect(ExposureStabilizer.decide(meteredISO: 400, ev: 0, current: nil,
                                           minimum: 25, maximum: 6400) == .apply(iso: 400))
        #expect(ExposureStabilizer.decide(meteredISO: 4000, ev: 3, current: nil,
                                           minimum: 25, maximum: 6400) == .apply(iso: 6400))
        #expect(ExposureStabilizer.decide(meteredISO: .nan, ev: 1, current: nil,
                                           minimum: 25, maximum: 6400) == .hold)
    }

    @Test func rejectsCompoundingWhenTheMeterEchoesThePinnedISO() {
        // The pin already carries +1 EV: raw 400 was written as 800.
        let pin = ExposureStabilizer.Pin(iso: 800, ev: 1, meteredISO: 400)
        // The device did not actually re-meter and returns the applied 800.
        // Deriving again would write 1600 and stack the compensation cycle
        // after cycle, which is the runaway the fix must reject.
        #expect(ExposureStabilizer.decide(meteredISO: 800, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .hold)
        // Feeding the same raw meter twice does not apply the EV twice either.
        #expect(ExposureStabilizer.decide(meteredISO: 400, ev: 1, current: pin,
                                           minimum: 25, maximum: 6400) == .hold)
        // A genuine EV change is honoured, not swallowed by the echo guard.
        #expect(ExposureStabilizer.decide(meteredISO: 400, ev: 0, current: pin,
                                           minimum: 25, maximum: 6400) == .apply(iso: 400))
    }

    // MARK: - Indicator mapping

    @Test func indicatorReportsAMatchOnlyWhenTheMeterAgreesWithTheTarget() {
        #expect(ExposureIndicatorPolicy.matches(meteredEV: -0.4, targetEV: -0.4))
        #expect(!ExposureIndicatorPolicy.matches(meteredEV: 0.0, targetEV: -0.4))
        // Tolerance boundary is inclusive.
        #expect(ExposureIndicatorPolicy.matches(meteredEV: -0.5, targetEV: -0.4))
        #expect(!ExposureIndicatorPolicy.matches(meteredEV: -0.6, targetEV: -0.4))
        #expect(!ExposureIndicatorPolicy.matches(meteredEV: .nan, targetEV: -0.4))
        #expect(!ExposureIndicatorPolicy.matches(meteredEV: -0.4, targetEV: .nan))
    }

    @Test func indicatorPositionIsMonotonicAndClampedToTheBar() {
        #expect(ExposureIndicatorPolicy.position(ev: 0) == 0.5)
        #expect(ExposureIndicatorPolicy.position(ev: -2) == 0)
        #expect(ExposureIndicatorPolicy.position(ev: 2) == 1)
        // Clamped beyond full scale rather than running off the bar.
        #expect(ExposureIndicatorPolicy.position(ev: -5) == 0)
        #expect(ExposureIndicatorPolicy.position(ev: 5) == 1)
        // Under sits left of centre, over sits right.
        #expect(ExposureIndicatorPolicy.position(ev: -0.4) < 0.5)
        #expect(ExposureIndicatorPolicy.position(ev: 0.4) > 0.5)
        // Monotonic across the whole scale.
        let samples: [Float] = [-3, -1, -0.4, 0, 0.4, 1, 3]
        let positions = samples.map { ExposureIndicatorPolicy.position(ev: $0) }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 })
        // Degenerate scale falls back to centre instead of dividing by zero.
        #expect(ExposureIndicatorPolicy.position(ev: 1, fullScaleEV: 0) == 0.5)
        #expect(ExposureIndicatorPolicy.position(ev: .nan) == 0.5)
    }

    // MARK: - Offset-driven correction

    @Test func settledNonzeroTargetsDoNotReturnToNeutral() {
        for target: Float in [-2, -1, 1, 2] {
            #expect(ExposureStabilizer.correctedISO(
                heldISO: 800, meteredOffsetEV: target, targetEV: target,
                minimum: 25, maximum: 6400) == 800)
        }
    }

    @Test func sceneChangesCorrectTowardTheSelectedTarget() {
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 2, targetEV: 1,
            minimum: 25, maximum: 6400) == 400)
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: -2, targetEV: -1,
            minimum: 25, maximum: 6400) == 1600)
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 0, targetEV: 1,
            minimum: 25, maximum: 6400) == 1600)
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 0, targetEV: -1,
            minimum: 25, maximum: 6400) == 400)
    }

    @Test func explicitEVChangesUseOnlyTheDeltaWithoutCompounding() throws {
        var pin = ExposureStabilizer.Pin(iso: 400, ev: 0, meteredISO: 400)
        let targets: [Float] = [1, 2, 2, 1, 0, -1, -2, 0]
        let expectedISOs: [Float] = [800, 1600, 1600, 800, 400, 200, 100, 400]
        for (target, expectedISO) in zip(targets, expectedISOs) {
            let iso = try #require(ExposureStabilizer.retargetedISO(
                pin: pin, targetEV: target, minimum: 25, maximum: 6400))
            #expect(iso == expectedISO)
            pin = ExposureStabilizer.Pin(iso: iso, ev: target, meteredISO: pin.meteredISO)
            #expect(ExposureStabilizer.correctedISO(
                heldISO: pin.iso, meteredOffsetEV: target, targetEV: target,
                minimum: 25, maximum: 6400) == iso)
        }
    }

    @Test func explicitEVChangesBypassTheSceneDeadband() throws {
        let pin = ExposureStabilizer.Pin(iso: 800, ev: 1, meteredISO: 400)
        let iso = try #require(ExposureStabilizer.retargetedISO(
            pin: pin, targetEV: 1.1, minimum: 25, maximum: 6400))
        #expect(iso > pin.iso)
        #expect(abs(log2(iso / pin.iso) - 0.1) < 0.0001)
    }

    @Test func clampedEVChangesDoNotReapplyFullCompensation() throws {
        let original = ExposureStabilizer.Pin(iso: 4000, ev: 0, meteredISO: 4000)
        let clamped = try #require(ExposureStabilizer.retargetedISO(
            pin: original, targetEV: 1, minimum: 25, maximum: 6400))
        #expect(clamped == 6400)
        let updated = ExposureStabilizer.Pin(iso: clamped, ev: 1, meteredISO: original.meteredISO)
        #expect(ExposureStabilizer.retargetedISO(
            pin: updated, targetEV: 1, minimum: 25, maximum: 6400) == 6400)
        #expect(ExposureStabilizer.retargetedISO(
            pin: updated, targetEV: 0, minimum: 25, maximum: 6400) == 3200)
    }

    @Test func explicitEVChangesScaleTheSceneCorrectedPinNotTheOriginalMeter() {
        let pin = ExposureStabilizer.Pin(iso: 1200, ev: 1, meteredISO: 400)
        #expect(ExposureStabilizer.retargetedISO(
            pin: pin, targetEV: 0, minimum: 25, maximum: 6400) == 600)
        #expect(ExposureStabilizer.retargetedISO(
            pin: pin, targetEV: 2, minimum: 25, maximum: 6400) == 2400)
    }

    @Test func targetCorrectionClampsAndRejectsUnusableInputs() {
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 0, targetEV: 1000,
            minimum: 25, maximum: 6400) == 6400)
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 0, targetEV: -1000,
            minimum: 25, maximum: 6400) == 25)
        for target: Float in [.nan, .infinity, -.infinity] {
            #expect(ExposureStabilizer.correctedISO(
                heldISO: 800, meteredOffsetEV: 0, targetEV: target,
                minimum: 25, maximum: 6400) == nil)
            #expect(ExposureStabilizer.retargetedISO(
                pin: .init(iso: 800, ev: 1, meteredISO: 400), targetEV: target,
                minimum: 25, maximum: 6400) == nil)
        }
        #expect(ExposureStabilizer.correctedISO(
            heldISO: .infinity, meteredOffsetEV: 0, targetEV: 1,
            minimum: 25, maximum: 6400) == nil)
        #expect(ExposureStabilizer.correctedISO(
            heldISO: 800, meteredOffsetEV: 0, targetEV: 1,
            minimum: 6400, maximum: 25) == nil)
        #expect(ExposureStabilizer.retargetedISO(
            pin: .init(iso: 800, ev: .nan, meteredISO: 400), targetEV: 1,
            minimum: 25, maximum: 6400) == nil)
        #expect(ExposureStabilizer.retargetedISO(
            pin: .init(iso: 800, ev: 0, meteredISO: 400), targetEV: 10,
            minimum: 25, maximum: 6400) == 6400)
    }

    @Test func correctedIsoScalesTheHeldIsoByTwoToTheMinusOffset() {
        // Convention measured on device: a positive offset means the image is
        // brighter than the target, so the held ISO comes down.
        #expect(ExposureStabilizer.correctedISO(heldISO: 800, meteredOffsetEV: 1,
                                                minimum: 25, maximum: 6400) == 400)
        #expect(ExposureStabilizer.correctedISO(heldISO: 800, meteredOffsetEV: -1,
                                                minimum: 25, maximum: 6400) == 1600)
        // The measured probe: two stops darker reported about -2 EV, and
        // correcting it returns to the ISO whose offset was ~0.
        let corrected = try? #require(ExposureStabilizer.correctedISO(
            heldISO: 177, meteredOffsetEV: -2.014, minimum: 25, maximum: 6400))
        #expect(abs((corrected ?? 0) - 713) < 5)
        // A settled pin is untouched.
        #expect(ExposureStabilizer.correctedISO(heldISO: 800, meteredOffsetEV: 0,
                                                minimum: 25, maximum: 6400) == 800)
        // Clamped to the format's range, and unusable input holds.
        #expect(ExposureStabilizer.correctedISO(heldISO: 800, meteredOffsetEV: -8,
                                                minimum: 25, maximum: 6400) == 6400)
        #expect(ExposureStabilizer.correctedISO(heldISO: 800, meteredOffsetEV: .nan,
                                                minimum: 25, maximum: 6400) == nil)
        #expect(ExposureStabilizer.correctedISO(heldISO: 0, meteredOffsetEV: 0,
                                                minimum: 25, maximum: 6400) == nil)
    }

    // MARK: - Shutter-matched ISO

    @Test func shutterMatchedIsoConvertsTheWholeExposureToTheFilmShutter() throws {
        // The reported bug: a bright scene meters ISO 800 at 1/480, and the take
        // starts at 1/48. Copying the ISO alone collects ten times the light;
        // the normalized ISO holds the same exposure.
        let iso = try #require(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 800, meteredDuration: 1.0 / 480.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 6400))
        #expect(abs(iso - 80) < 0.001)
        #expect(abs(iso - 800 * (1.0 / 480.0) / (1.0 / 48.0)) < 0.001)

        // The other direction: a dim scene meters ISO 100 at 1/24 and the take
        // holds 1/48, so the gain doubles.
        let dim = try #require(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 100, meteredDuration: 1.0 / 24.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 6400))
        #expect(abs(dim - 200) < 0.001)

        // An unchanged shutter is a no-op.
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: -1, targetEV: -1, minimum: 25, maximum: 6400) == 400)
    }

    @Test func shutterMatchedIsoAppliesTheNeutralOffsetOnce() throws {
        // Installed bias is part of the neutral offset, so a converged meter at
        // an installed -1 EV target asks for no extra compensation: the scene is
        // already where the operator put it.
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: -1, targetEV: -1, minimum: 25, maximum: 6400) == 400)
        // The operator asks for a stop more: the ISO doubles, once.
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: -1, targetEV: 0, minimum: 25, maximum: 6400) == 800)
        // A residual metering error is corrected from the scene, not compounded:
        // the truncated scene cut exposure, so the offset corrects back toward
        // the target and the duration conversion still applies.
        let iso = try #require(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 800, meteredDuration: 1.0 / 480.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: -2, targetEV: -1, minimum: 25, maximum: 6400))
        #expect(abs(iso - 160) < 0.001)
    }

    @Test func shutterMatchedIsoClampsAfterTheAdjustment() {
        // Normalization first, clamp second: a reading that would overflow at the
        // metered duration still lands at the format's ceiling for the take.
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 6400, meteredDuration: 1.0 / 24.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 3, minimum: 25, maximum: 6400) == 6400)
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 25, meteredDuration: 1.0 / 480.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: -3, minimum: 25, maximum: 6400) == 25)
        // A clamp is still a real brightness change; it is never reported as the
        // unclamped value.
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 100, meteredDuration: 1.0 / 24.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 150) == 150)
    }

    @Test func shutterMatchedIsoRejectsUnusableInputs() {
        // Durations.
        for duration: Double in [.nan, .infinity, 0, -1.0 / 48.0] {
            #expect(ExposureStabilizer.shutterMatchedISO(
                meteredISO: 400, meteredDuration: duration, targetDuration: 1.0 / 48.0,
                meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 6400) == nil)
            #expect(ExposureStabilizer.shutterMatchedISO(
                meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: duration,
                meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 6400) == nil)
        }
        // ISO, offsets, and bounds.
        for iso: Float in [.nan, .infinity, 0, -400] {
            #expect(ExposureStabilizer.shutterMatchedISO(
                meteredISO: iso, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
                meteredOffsetEV: 0, targetEV: 0, minimum: 25, maximum: 6400) == nil)
        }
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: .nan, targetEV: 0, minimum: 25, maximum: 6400) == nil)
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: .infinity, minimum: 25, maximum: 6400) == nil)
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 0, minimum: 6400, maximum: 25) == nil)
        #expect(ExposureStabilizer.shutterMatchedISO(
            meteredISO: 400, meteredDuration: 1.0 / 48.0, targetDuration: 1.0 / 48.0,
            meteredOffsetEV: 0, targetEV: 0, minimum: 0, maximum: 6400) == nil)
    }
}
