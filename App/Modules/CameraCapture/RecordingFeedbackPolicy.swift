import Foundation

/// Timing for the press-to-count sequence on the REC control.
enum RecordButtonTimingPolicy {
    /// How long a take really takes to begin capturing, modelled rather than
    /// measured. The recorder drops frames captured before the recording exposure
    /// takes effect, which on the iPhone 18 Pro lands 0.19–0.22 s after the tap in
    /// every stabilization mode — while the writer can take 2.2 s to say so. The
    /// counter's zero point is this delay after the tap, so the display is
    /// continuous and matches the file instead of starting when capture confirms.
    static let captureStartDelay: TimeInterval = 0.2

    /// When the pressed face springs back. Short enough to feel like the button
    /// releasing under the finger, long enough to be seen.
    static let unclickDelay: TimeInterval = 0.1

    /// The instant a counter counts from for a take requested at `tapAt`.
    static func timerOrigin(tapAt: Date) -> Date {
        tapAt.addingTimeInterval(captureStartDelay)
    }
}

/// How the on-screen counter compared with the file that was actually written.
enum RecordingDurationDiscrepancy: Equatable, Sendable {
    /// Within tolerance: the modelled origin matched the recording.
    case withinTolerance
    /// Worth recording, but not worth interrupting the user.
    case logged(TimeInterval)
    /// The file is materially shorter than the counter showed, so the take is
    /// missing content the user was told they had.
    case contentMissing(TimeInterval)
}

/// Self-check for the counter's model of when a take starts.
enum RecordingDurationDiscrepancyPolicy {
    /// Anything beyond this is written to the log, because it would reveal a
    /// wrong model rather than ordinary variation between the modelled 0.2 s
    /// origin and the measured one.
    static let logThreshold: TimeInterval = 0.5

    /// Only a real shortfall this large changes what the user expects to have
    /// recorded. A file that is *longer* than the counter never surfaces: the
    /// recorder drains video slightly past the stop request, which is expected.
    static let userVisibleShortfall: TimeInterval = 2.0

    static func verdict(displayed: TimeInterval, actual: TimeInterval) -> RecordingDurationDiscrepancy {
        guard displayed.isFinite, actual.isFinite else { return .withinTolerance }
        let difference = actual - displayed
        guard abs(difference) > logThreshold else { return .withinTolerance }
        if difference < 0, -difference >= userVisibleShortfall {
            return .contentMissing(-difference)
        }
        return .logged(difference)
    }
}
