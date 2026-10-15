import Testing

struct RecordButtonPresentationTests {
    @Test func recordingWinsOverStarting() {
        #expect(RecordButtonPresentationPolicy.presentation(isRecording: true, isStarting: false) == .recording)
        #expect(RecordButtonPresentationPolicy.presentation(isRecording: true, isStarting: true) == .recording)
        #expect(RecordButtonPresentationPolicy.presentation(isRecording: false, isStarting: true) == .starting)
        #expect(RecordButtonPresentationPolicy.presentation(isRecording: false, isStarting: false) == .idle)
    }

    @Test func idleIsDisabledOnlyWhenSpaceIsCritical() {
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: false, presentation: .idle))
        #expect(!RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .idle))
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .starting))
        #expect(RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: true, presentation: .recording))
    }

    @Test func startingAndRecordingBothStop() {
        #expect(RecordButtonPresentationPolicy.action(for: .idle) == .start)
        #expect(RecordButtonPresentationPolicy.action(for: .starting) == .stop)
        #expect(RecordButtonPresentationPolicy.action(for: .recording) == .stop)
    }

    @Test func accessibilityLabelsDescribeEachState() {
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .idle) == "Start recording")
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .starting) == "Cancel starting recording")
        #expect(RecordButtonPresentationPolicy.accessibilityLabel(for: .recording) == "Stop recording")
    }
}
