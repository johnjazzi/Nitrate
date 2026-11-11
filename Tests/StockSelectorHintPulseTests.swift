import Foundation
import Testing

/// Semantic coverage for the gentle pulse treatment of the stock-selector hint.
///
/// The pulse is a pure function of time since the cue appeared, so these tests
/// assert the shape of the whole 3-second envelope: three smooth low-to-high-to-low
/// cycles, a dim-but-visible trough, bounded opacity, and a clean lifetime. They
/// never inspect SwiftUI source strings; the view reuses these same constants so
/// it cannot drift from the contract.
@Suite("Stock selector hint pulse")
struct StockSelectorHintPulseTests {

    // MARK: - Lifetime

    @Test func lifetimeIsThreeOneSecondCyclesOfTheExistingCue() {
        #expect(StockSelectorHintPulse.cycleCount == 3)
        #expect(StockSelectorHintPulse.cycleDuration == 1)
        #expect(StockSelectorHintPulse.totalDuration == 3)
        // The pulse fills exactly the cue's existing ~3 s on-screen lifetime.
        #expect(StockSelectorHintPulse.totalDuration == StockSelectorHintPolicy.cueDuration)
    }

    @Test func opacityIsZeroOutsideTheCueLifetimeAndStartsAtTheDimLow() {
        #expect(StockSelectorHintPulse.opacity(elapsed: 0) == StockSelectorHintPulse.minimumOpacity)
        #expect(StockSelectorHintPulse.opacity(elapsed: -0.001) == 0)
        #expect(StockSelectorHintPulse.opacity(elapsed: StockSelectorHintPulse.totalDuration) == 0)
        #expect(StockSelectorHintPulse.opacity(elapsed: StockSelectorHintPulse.totalDuration + 1) == 0)
        #expect(StockSelectorHintPulse.opacity(elapsed: .nan) == 0)
        #expect(StockSelectorHintPulse.opacity(elapsed: .infinity) == 0)
    }

    // MARK: - Shape

    @Test func pulsesExactlyThreeTimesSpacedOneSecondApart() {
        let step = 0.005
        let steps = Int((StockSelectorHintPulse.totalDuration / step).rounded())
        var peaks: [Double] = []
        var previous = StockSelectorHintPulse.opacity(elapsed: 0)
        var current = StockSelectorHintPulse.opacity(elapsed: step)
        for index in 2...steps {
            let time = Double(index) * step
            let next = StockSelectorHintPulse.opacity(elapsed: time)
            if current > previous, current >= next, current > 0.99 {
                peaks.append(time - step)
            }
            previous = current
            current = next
        }

        #expect(peaks.count == StockSelectorHintPulse.cycleCount)
        #expect(peaks.count == 3)
        for (peak, expected) in zip(peaks, [0.5, 1.5, 2.5]) {
            #expect(abs(peak - expected) < 0.02)
        }
    }

    @Test func opacityStaysDimButVisibleBetweenTheLowsAndFull() {
        #expect(StockSelectorHintPulse.minimumOpacity > 0)
        #expect(StockSelectorHintPulse.minimumOpacity < StockSelectorHintPulse.maximumOpacity)
        let samples = 2_000
        for index in 0..<samples {
            let elapsed = Double(index) / Double(samples) * StockSelectorHintPulse.totalDuration
            let value = StockSelectorHintPulse.opacity(elapsed: elapsed)
            #expect(value >= StockSelectorHintPulse.minimumOpacity - 1e-9)
            #expect(value <= StockSelectorHintPulse.maximumOpacity + 1e-9)
            // The trough is a breath, never a black blink.
            #expect(value > 0)
        }
    }

    @Test func cyclesJoinAtTheDimLowWithoutABlink() {
        // The trough is reached smoothly and is never zero, so a cycle boundary
        // reads as a breath rather than a flicker.
        #expect(StockSelectorHintPulse.opacity(elapsed: StockSelectorHintPulse.cycleDuration)
                == StockSelectorHintPulse.minimumOpacity)
        #expect(StockSelectorHintPulse.opacity(elapsed: StockSelectorHintPulse.cycleDuration * 2)
                == StockSelectorHintPulse.minimumOpacity)
        let epsilon = 0.001
        for boundary in [StockSelectorHintPulse.cycleDuration, StockSelectorHintPulse.cycleDuration * 2] {
            let before = StockSelectorHintPulse.opacity(elapsed: boundary - epsilon)
            let after = StockSelectorHintPulse.opacity(elapsed: boundary + epsilon)
            #expect(abs(before - after) < 0.01)
            #expect(before > 0)
            #expect(after > 0)
        }
    }

    // MARK: - Restart

    @Test func restartingTheCueBeginsAtTheDimLowAndRepeatsTheFirstEnvelope() {
        // A pure function of time-since-appearance: a restart (elapsed back to 0)
        // always resumes at the dim low, with nothing carried over from a previous
        // preview. Each cycle repeats the first, so the phase is periodic.
        #expect(StockSelectorHintPulse.opacity(elapsed: 0) == StockSelectorHintPulse.minimumOpacity)
        let period = StockSelectorHintPulse.cycleDuration
        for index in 0..<20 {
            let offset = Double(index) / 20 * period
            let first = StockSelectorHintPulse.opacity(elapsed: offset)
            #expect(abs(StockSelectorHintPulse.opacity(elapsed: offset + period) - first) < 1e-9)
            #expect(abs(StockSelectorHintPulse.opacity(elapsed: offset + 2 * period) - first) < 1e-9)
        }
    }
}
