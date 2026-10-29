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

    /// A setter acknowledgement that never arrives must not hold the shutter
    /// hostage. AVFoundation has been observed to drop one after a profile
    /// rebuild; the in-flight flag then stayed set and the shutter was greyed out
    /// for the rest of the session with nothing said. Past this the flag is
    /// dropped and the next cycle re-reads the device, which is the only source
    /// of truth for the value actually installed.
    static let setterTimeout: TimeInterval = 1.2

    /// How long a shutter tap may wait for the exposure to settle before it fails
    /// with a reason. A capture that cannot start has to say so rather than leave
    /// the operator tapping an apparently dead control.
    static let captureTimeout: TimeInterval = 3.0

    /// How long a waiting capture defers to the operator's own unwritten intent
    /// before taking the photo with the exposure already installed. This is the
    /// same window as a gesture debounce: long enough to honour a value the
    /// operator just set, short enough that the shutter never feels unresponsive.
    static let captureImpatience: TimeInterval = 0.2

    /// How long a RAW capture transaction may wait for the framework's terminal
    /// callback before the session closes it itself.
    ///
    /// A dropped terminal (the same class of loss already observed on a setter
    /// acknowledgement) used to leave `capturing` set forever: the shutter was
    /// dead for the rest of the session, the readiness reported "not ready", and
    /// nothing said why. A RAW still that has not terminated by now is not coming,
    /// and the operator has to be able to take the next photo.
    static let captureTransactionTimeout: TimeInterval = 8

    static func needsWrite(iso: Float, duration: Double, actualISO: Float, actualDuration: Double) -> Bool {
        abs(iso - actualISO) > max(1, abs(actualISO) * 0.005)
            || abs(duration - actualDuration) > max(0.000005, actualDuration * 0.005)
    }
}
