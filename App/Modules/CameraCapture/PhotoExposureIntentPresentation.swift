import Foundation

/// Keeps touch intent visible while device snapshots acknowledge it asynchronously.
struct PhotoExposureIntentPresentation: Equatable {
    private(set) var duration: Double
    private(set) var shutterLocked: Bool
    private(set) var pendingDuration: Double?
    private(set) var pendingLock: Bool?
    private(set) var range: ClosedRange<Double>
    private(set) var iso: Float
    private(set) var pendingISO: Float?
    private(set) var isoRange: ClosedRange<Float>

    init(snapshot: PhotoExposureSnapshot) {
        duration = snapshot.durationSeconds
        shutterLocked = snapshot.shutterLocked
        range = snapshot.shutterRange
        iso = snapshot.iso
        isoRange = snapshot.isoRange
    }

    /// The operator moved the ISO ruler. Both readouts stay on this value until the
    /// device reports it back: writing the snapshot straight into the presented ISO
    /// yanked the ruler out from under the finger on every publish, so the next drag
    /// delta was measured from a position the operator never chose and the control
    /// stuttered seconds behind the touch.
    mutating func selectISO(_ value: Float) {
        guard value.isFinite, isoRange.contains(value) else { return }
        iso = value
        pendingISO = value
    }

    mutating func select(duration value: Double) {
        guard value.isFinite, range.contains(value) else { return }
        duration = value
        pendingDuration = value
        setLocked(true)
    }

    mutating func setLocked(_ value: Bool) {
        shutterLocked = value
        pendingLock = value
        if !value {
            pendingDuration = nil
        }
    }

    mutating func unlock() {
        setLocked(false)
    }

    mutating func reconcile(_ snapshot: PhotoExposureSnapshot) {
        reconcileISO(snapshot)
        guard snapshot.shutterRange != range else {
            if let pendingDuration {
                if snapshot.shutterLocked,
                   abs(snapshot.durationSeconds - pendingDuration) <= max(0.000001, pendingDuration * 0.001) {
                    self.pendingDuration = nil
                    duration = snapshot.durationSeconds
                }
            } else {
                duration = snapshot.durationSeconds
            }
            if let pendingLock {
                if snapshot.shutterLocked == pendingLock { self.pendingLock = nil }
            } else {
                shutterLocked = snapshot.shutterLocked
            }
            return
        }
        range = snapshot.shutterRange
        duration = snapshot.durationSeconds
        pendingDuration = nil
        shutterLocked = snapshot.shutterLocked
        pendingLock = nil
    }

    private mutating func reconcileISO(_ snapshot: PhotoExposureSnapshot) {
        guard snapshot.isoRange == isoRange else {
            // A different format's band invalidates any pending selection in it.
            isoRange = snapshot.isoRange
            iso = snapshot.iso
            pendingISO = nil
            return
        }
        guard let pendingISO else {
            iso = snapshot.iso
            return
        }
        // The device quantises ISO to the format's granularity, so equality is not
        // the test for "installed": the write path's own tolerance decides, which
        // also keeps the shutter side out of it by comparing like with like.
        if !PhotoExposureCadence.needsWrite(iso: pendingISO, duration: snapshot.durationSeconds,
                                            actualISO: snapshot.iso,
                                            actualDuration: snapshot.durationSeconds) {
            self.pendingISO = nil
            iso = snapshot.iso
        }
    }

    var measuredDuration: Double? { pendingDuration == nil ? duration : nil }

    var measuredISO: Float? { pendingISO == nil ? iso : nil }
}
