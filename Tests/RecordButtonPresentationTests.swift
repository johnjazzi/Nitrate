import Testing

struct RecordButtonPresentationTests {
    @Test func stoppingWinsOverRecordingAndStarting() {
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: true, isStarting: false, isStopping: true) == .stopping)
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: true, isStarting: true, isStopping: true) == .stopping)
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: true, isStopping: true) == .stopping)
    }

    @Test func recordingWinsOverStarting() {
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: true, isStarting: false, isStopping: false) == .recording)
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: true, isStarting: true, isStopping: false) == .recording)
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: true, isStopping: false) == .starting)
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: false, isStopping: false) == .idle)
    }

    @Test func idleIsDisabledOnlyWhenSpaceIsCritical() {
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: false, presentation: .idle))
        #expect(!RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .idle))
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .starting))
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .recording))
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .stopping))
    }

    @Test func startingAndRecordingStopWhileStoppingIgnoresTheTap() {
        #expect(RecordButtonPresentationPolicy.action(for: .idle) == .start)
        #expect(RecordButtonPresentationPolicy.action(for: .starting) == .stop)
        #expect(RecordButtonPresentationPolicy.action(for: .recording) == .stop)
        #expect(RecordButtonPresentationPolicy.action(for: .stopping) == .none)
    }

    @Test func accessibilityLabelsDescribeEachState() {
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .idle) == "Start recording")
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .starting) == "Cancel starting recording")
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .stopping) == "Stopping recording")
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .recording) == "Stop recording")
    }

    // MARK: - Optimistic contract

    @Test func liveChromeIncludesStartupButNotIdleOrFinalizing() {
        #expect(RecordButtonPresentation.starting.showsLiveChrome)
        #expect(RecordButtonPresentation.recording.showsLiveChrome)
        #expect(!RecordButtonPresentation.idle.showsLiveChrome)
        #expect(!RecordButtonPresentation.stopping.showsLiveChrome)
    }

    /// The tap is accepted at once: the control enters `.starting` while capture
    /// spins up, and never has to be confirmed before it can answer. This is the
    /// state the tally, the timer and the lens-hiding all follow.
    @Test func aRecordTapEntersTheStartingStateBeforeCaptureConfirms() {
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: true, isStopping: false) == .starting)
    }

    /// A second tap inside the startup window cancels the pending start — it does
    /// not queue another take — and cancelling rolls the control back to idle.
    @Test func aSecondTapDuringStartupCancelsAndRollsBack() {
        let pending = RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: true, isStopping: false)
        #expect(RecordButtonPresentationPolicy.action(for: pending) == .stop,
                "A pending start must be cancellable from the same control.")
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: false, isStopping: false) == .idle,
                "A cancelled start rolls back to idle.")
    }

    /// A failed start clears the pending flag and never confirms, so the control
    /// rolls back to idle and its optimistic chrome disappears with the error.
    @Test func aFailedStartRollsBackToIdle() {
        #expect(RecordButtonPresentationPolicy.presentation(
            isRecording: false, isStarting: false, isStopping: false) == .idle)
        #expect(RecordButtonPresentationPolicy.action(for: .idle) == .start,
                "After the rollback the control must start a fresh take, not stop.")
    }
}
