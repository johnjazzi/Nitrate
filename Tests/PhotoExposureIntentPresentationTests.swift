import Foundation
import Testing

struct PhotoExposureIntentPresentationTests {
    private func snapshot(duration: Double = 1.0 / 30, locked: Bool = false,
                          range: ClosedRange<Double> = 1.0 / 8000...30,
                          iso: Float = 100, isoRange: ClosedRange<Float> = 50...6400) -> PhotoExposureSnapshot {
        PhotoExposureSnapshot(iso: iso, durationSeconds: duration, isoRange: isoRange,
            shutterRange: range, isoLocked: false, shutterLocked: locked, ev: 0,
            meteringOffset: 0, isSettling: false, canCapture: true, targetLimited: false)
    }

    @Test func pendingTouchSurvivesOldHardwareSnapshotUntilAcknowledged() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.select(duration: 1.0 / 15)
        state.reconcile(snapshot())
        #expect(state.duration == 1.0 / 15)
        #expect(state.measuredDuration == nil)
        state.reconcile(snapshot(duration: 1.0 / 15, locked: true))
        #expect(state.duration == 1.0 / 15)
        #expect(state.measuredDuration == 1.0 / 15)
    }

    @Test func quantizedHardwareValueAcknowledgesRequestedDuration() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.select(duration: 0.5)
        state.reconcile(snapshot(duration: 0.499901, locked: true))
        #expect(state.pendingDuration == nil)
        #expect(state.measuredDuration == 0.499901)
    }

    @Test func writerNoOpQuantizationAcknowledgesPendingShutter() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot(duration: 0.000997, locked: true))
        state.select(duration: 0.001)
        #expect(!PhotoExposureCadence.needsWrite(iso: 100, duration: 0.001,
                                               actualISO: 100, actualDuration: 0.000997))
        state.reconcile(snapshot(duration: 0.000997, locked: true))
        #expect(state.pendingDuration == nil)
        #expect(state.measuredDuration == 0.000997)
    }

    @Test func selectingDurationLocksAndUnlockCancelsPendingAndFloats() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.select(duration: 1)
        #expect(state.shutterLocked)
        state.unlock()
        #expect(!state.shutterLocked)
        #expect(state.pendingDuration == nil)
        #expect(state.measuredDuration == state.duration)
    }

    @Test func rapidLockTogglesComposeFromLatestIntent() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.setLocked(!state.shutterLocked)
        state.setLocked(!state.shutterLocked)
        #expect(state.shutterLocked == false)
        state.reconcile(snapshot())
        #expect(state.shutterLocked == false)
    }

    @Test func changedRangeCancelsIncompatiblePendingSelection() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.select(duration: 1)
        state.reconcile(snapshot(duration: 1.0 / 30, range: 1.0 / 4000...1.0 / 4))
        #expect(state.duration == 1.0 / 30)
        #expect(state.measuredDuration == 1.0 / 30)
    }

    @Test func shortExposureDoesNotAcknowledgeDifferentDetent() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot(duration: 1.0 / 8000))
        state.select(duration: 1.0 / 6400)
        state.reconcile(snapshot(duration: 1.0 / 8000, locked: true))
        #expect(state.pendingDuration == 1.0 / 6400)
    }

    /// The ISO ruler is the same contract as the shutter rail: the operator's
    /// value stays presented until the device acknowledges it. Regressing this is
    /// what made the ISO slider stutter and lag behind the finger in Photo mode.
    @Test func pendingISOSurvivesStaleHardwareSnapshotsUntilAcknowledged() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.selectISO(1600)
        state.reconcile(snapshot())
        #expect(state.iso == 1600)
        #expect(state.measuredISO == nil)
        state.reconcile(snapshot(iso: 1600))
        #expect(state.iso == 1600)
        #expect(state.measuredISO == 1600)
    }

    /// The device quantises ISO to its own granularity: a close reading is an
    /// acknowledgement, not a reason to keep the pending value alive.
    @Test func quantisedDeviceISOAcknowledgesTheRequestedValue() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.selectISO(1600)
        state.reconcile(snapshot(iso: 1603))
        #expect(state.pendingISO == nil)
        #expect(state.iso == 1603)
    }

    @Test func aDifferentISOFormatBandCancelsThePendingSelection() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.selectISO(12800)
        state.reconcile(snapshot(iso: 800, isoRange: 50...3200))
        #expect(state.iso == 800)
        #expect(state.pendingISO == nil)
    }

    @Test func explicitRapidLockUpdatesKeepLatestIntent() {
        var state = PhotoExposureIntentPresentation(snapshot: snapshot())
        state.setLocked(true)
        state.setLocked(false)
        state.reconcile(snapshot())
        #expect(!state.shutterLocked)
        #expect(state.pendingLock == nil)
    }
}
