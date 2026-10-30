import Foundation

/// Monotonic deadlines shared by debounced user intent and sensor corrections.
enum PhotoExposureCadence {
    static let gestureDelay: TimeInterval = 0.12

    /// How soon an operator-driven intent may follow the previous acknowledged
    /// write. Deliberately independent of the exposure duration: a long shutter
    /// slows the sensor, not the operator's control. Scaling this by the shutter
    /// made a drag feel frozen exactly when the rail reached the slow end.
    static let commandInterval: TimeInterval = 0.15

    /// How long a metering-driven correction waits before trusting a reading
    /// taken under the exposure it just applied: two exposures plus a settle
    /// margin, so the auto loop never chases its own writes.
    static func measurementInterval(duration: Double) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0.3 }
        return max(0.3, duration * 2 + 0.15)
    }

    /// Bounded logical acknowledgement lease for noncapture setters. Expiry
    /// fences late callbacks and requires a session stop/reconfigure; it is not
    /// proof of a physical terminal and never releases RAW capture ownership.
    static let setterTimeout: TimeInterval = 1.2

    /// A setter's deadline has to outlive the exposure it installs. A one second
    /// shutter acknowledged inside a fixed 1.2 s budget expired on real hardware
    /// and marked the session as requiring recovery, which then refused every
    /// later EV write and capture until the app restarted.
    static func setterDeadline(forRequestedDuration seconds: Double) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return setterTimeout }
        return max(setterTimeout, seconds * 2 + 0.3)
    }

    /// How long a shutter tap may wait for the exposure to settle before it fails
    /// with a reason. A capture that cannot start has to say so rather than leave
    /// the operator tapping an apparently dead control.
    static let captureTimeout: TimeInterval = 3.0

    /// How long a waiting capture defers to the operator's own unwritten intent
    /// before taking the photo with the exposure already installed. This is the
    /// same window as a gesture debounce: long enough to honour a value the
    /// operator just set, short enough that the shutter never feels unresponsive.
    static let captureImpatience: TimeInterval = 0.2

    /// Deadline for reporting a stalled RAW transaction. Timer expiry alone is
    /// NOT a framework terminal; capture/output ownership needs a real terminal
    /// callback or an explicitly coordinated session reset.
    static let captureTransactionTimeout: TimeInterval = 8

    static func needsWrite(iso: Float, duration: Double, actualISO: Float, actualDuration: Double) -> Bool {
        abs(iso - actualISO) > max(1, abs(actualISO) * 0.005)
            || abs(duration - actualDuration) > max(0.000005, actualDuration * 0.005)
    }
}
