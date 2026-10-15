import Testing

struct RecordingDurationTextTests {
    @Test func formatsHundredthsAsMinutesSecondsCentiseconds() {
        #expect(RecordingDurationText.format(seconds: 0) == "00:00.00")
        #expect(RecordingDurationText.format(seconds: 1.239) == "00:01.23")
        #expect(RecordingDurationText.format(seconds: 61.5) == "01:01.50")
        #expect(RecordingDurationText.format(seconds: 300) == "05:00.00")
    }

    @Test func truncatesRatherThanRounds() {
        // A running clock must not show a hundredth that has not elapsed yet.
        #expect(RecordingDurationText.format(seconds: 0.999) == "00:00.99")
        #expect(RecordingDurationText.format(seconds: 59.999) == "00:59.99")
    }

    @Test func binaryFloatErrorDoesNotPinTheDisplayALowHundredth() {
        // 0.29 * 100 == 28.999999999999996 in binary floating point.
        #expect(RecordingDurationText.format(seconds: 0.29) == "00:00.29")
        #expect(RecordingDurationText.format(seconds: 1.0) == "00:01.00")
        #expect(RecordingDurationText.format(seconds: 2.71) == "00:02.71")
    }

    @Test func unusableInputClampsToZero() {
        #expect(RecordingDurationText.format(seconds: -1) == "00:00.00")
        #expect(RecordingDurationText.format(seconds: .nan) == "00:00.00")
        #expect(RecordingDurationText.format(seconds: .infinity) == "00:00.00")
    }

    @Test func everyHundredthStepProducesAStrictlyIncreasingLabel() {
        var previous = ""
        for step in 0..<600 {
            let text = RecordingDurationText.format(seconds: Double(step) / 100)
            #expect(text > previous, "step \(step) produced \(text) after \(previous)")
            previous = text
        }
    }
}
