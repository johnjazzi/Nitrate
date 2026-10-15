import Foundation
import Testing

struct RecordButtonTimingPolicyTests {
    @Test func theCounterCountsFromWhereCaptureBegins() {
        let tap = Date(timeIntervalSince1970: 1_000)
        #expect(RecordButtonTimingPolicy.timerOrigin(tapAt: tap) == tap.addingTimeInterval(0.2))
    }

    @Test func theUnclickLandsBeforeCaptureBegins() {
        // The press has to read as released before the counter starts moving.
        #expect(RecordButtonTimingPolicy.unclickDelay < RecordButtonTimingPolicy.captureStartDelay)
        #expect(RecordButtonTimingPolicy.unclickDelay == 0.1)
        #expect(RecordButtonTimingPolicy.captureStartDelay == 0.2)
    }
}

struct RecordingDurationDiscrepancyPolicyTests {
    /// The verdicts carry a derived double, so compare with a tolerance rather
    /// than by exact equality.
    private func logged(_ verdict: RecordingDurationDiscrepancy) -> TimeInterval? {
        if case .logged(let difference) = verdict { return difference }
        return nil
    }

    private func shortfall(_ verdict: RecordingDurationDiscrepancy) -> TimeInterval? {
        if case .contentMissing(let value) = verdict { return value }
        return nil
    }

    private func isClose(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.000_001
    }

    @Test func ordinaryVariationIsNotWorthRecording() {
        // The modelled 0.2 s origin against a measured 0.19-0.22 s start, plus the
        // recorder draining a little past the stop request.
        #expect(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 10) == .withinTolerance)
        #expect(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 10.5) == .withinTolerance)
        #expect(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 9.5) == .withinTolerance)
    }

    @Test func aLongerFileIsLoggedButNeverSurfaced() {
        // The recorder drains video past the stop request, so a longer file is
        // expected behaviour rather than something to tell the user about.
        #expect(isClose(logged(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 11)), 1))
        #expect(isClose(logged(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 30)), 20))
    }

    @Test func aShortfallOverTheLogThresholdIsLoggedBeforeItIsSurfaced() {
        #expect(isClose(logged(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 9.2)), -0.8))
        #expect(isClose(logged(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 8.5)), -1.5))
    }

    @Test func aMaterialShortfallIsSurfaced() {
        #expect(isClose(shortfall(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 8)), 2))
        #expect(isClose(shortfall(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: 3)), 7))
    }

    @Test func unusableInputCannotProduceAFalseAlarm() {
        #expect(RecordingDurationDiscrepancyPolicy.verdict(displayed: .nan, actual: 10) == .withinTolerance)
        #expect(RecordingDurationDiscrepancyPolicy.verdict(displayed: 10, actual: .infinity) == .withinTolerance)
    }
}
