import Testing

/// The one capacity/remaining line both finishes print under the queue mark.
///
/// The approved face reports hundredths — `12.50 GB`, `1.98 min` — truncated
/// rather than rounded, so the readout never promises a minute or a gigabyte
/// the card cannot deliver. Classic and Minimal share this exact content.
@MainActor
struct RecordingCapacityReadoutTests {
    private func lcd(seconds: Double?, photoFreeBytes: Int64? = nil) -> RecordingTimeLCD {
        let queue = CameraStatusPresentation(outstandingCount: 0, pendingCount: 0, isProcessing: false,
            failedCount: 0, errorMessage: nil, latestResultCompleted: false, latestResultSavedToPhotos: false)
        return RecordingTimeLCD(estimatedSeconds: seconds, isStorageLow: false, queueStatus: queue,
                                photoFreeBytes: photoFreeBytes, isPhotoMode: photoFreeBytes != nil)
    }

    private func readout(seconds: Double?) -> String {
        lcd(seconds: seconds).minimalRemainingText
    }

    @Test func minutesNeverOverstateAvailableTime() {
        #expect(readout(seconds: 0) == "0.00 min")
        #expect(readout(seconds: 30) == "0.50 min")
        #expect(readout(seconds: 60) == "1.00 min")
        // 119s is 1.983 min: hundredths, truncated — never "1.99".
        #expect(readout(seconds: 119) == "1.98 min")
        #expect(readout(seconds: 754) == "12.56 min")
    }

    @Test func gigabytesNeverOverstateFreeSpace() {
        #expect(lcd(seconds: 754, photoFreeBytes: 12_500_000_000).minimalCapacityText == "12.50 GB")
        #expect(lcd(seconds: 754, photoFreeBytes: 97_300_000_000).minimalCapacityText == "97.30 GB")
        // 12.499 GB stays 12.49: the decimal is floored, not rounded.
        #expect(lcd(seconds: 754, photoFreeBytes: 12_499_000_000).minimalCapacityText == "12.49 GB")
        #expect(lcd(seconds: 754, photoFreeBytes: 0).minimalCapacityText == "0.00 GB")
        // A negative snapshot is clamped to zero, never printed as a minus.
        #expect(lcd(seconds: 754, photoFreeBytes: -1).minimalCapacityText == "0.00 GB")
    }

    @Test func unavailableOrInvalidCapacityHasAnHonestPlaceholder() {
        for value in [Double?.none, .some(-1), .some(.nan), .some(.infinity), .some(.greatestFiniteMagnitude)] {
            #expect(readout(seconds: value) == "-- min")
        }
        for bytes in [Int64?.none] {
            #expect(lcd(seconds: 754, photoFreeBytes: bytes).minimalCapacityText == "-- GB")
        }
    }

    @Test func bothFinishesPrintTheSameLine() {
        let video = lcd(seconds: 754).minimalReadoutText
        let photo = lcd(seconds: 754, photoFreeBytes: 12_500_000_000).minimalReadoutText
        #expect(video == "12.56 min")
        #expect(photo == "12.50 GB")
        #expect(RecordingTimeLCD.minimalReadoutSize == 12,
                "The line is 12pt in both finishes and for both media.")
        #expect(RecordingTimeLCD.queueGlyphSize == 22,
                "The mark above it is the approved 22pt glyph.")
    }
}
