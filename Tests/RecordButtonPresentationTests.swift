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
}
