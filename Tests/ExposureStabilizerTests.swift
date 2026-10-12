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
}
