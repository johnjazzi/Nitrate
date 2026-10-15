import Foundation

/// Formats the running REC timer to hundredths: `mm:ss.cc`.
///
/// Truncates rather than rounds, because a running clock must never show a
/// hundredth that has not elapsed yet. The epsilon absorbs binary floating-point
/// error (for example `0.29 * 100 == 28.999999999999996`), which would otherwise
/// pin the display a hundredth low for a whole tick.
enum RecordingDurationText {
    /// Scales by this before truncating: 1 µs, far below one display step
    /// (10 ms) and far above float error at these magnitudes.
    private static let truncationEpsilon = 1e-6

    static func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00.00" }
        let hundredths = Int((max(0, seconds) * 100 + truncationEpsilon).rounded(.down))
        let remainder = hundredths % 6000
        return String(format: "%02d:%02d.%02d", hundredths / 6000, remainder / 100, remainder % 100)
    }
}
