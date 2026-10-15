import Foundation
import Testing

struct RecordingFinishPresentationTests {
    private let url = URL(fileURLWithPath: "/tmp/clip.mov")

    @Test func normalTakeIsPlannedForRendering() {
        let completion = RecordingCompletion(url: url, warning: nil)
        #expect(RecordingFinishPresentationPolicy.plan(for: completion) == .render(url))
    }

    @Test func aKeptOriginalIsNeverPlannedForRendering() {
        let completion = RecordingCompletion(
            url: url,
            warning: CameraRetainedRecordingError(originalURL: url, reason: ValidationFailure.failed),
            retainedOriginal: true
        )
        #expect(RecordingFinishPresentationPolicy.plan(for: completion)
                == .saveOriginalUnchanged(url, reason: "validation failed"))
    }

    @Test func aKeptOriginalWithoutAReasonStillReadsSensibly() {
        let completion = RecordingCompletion(url: url, warning: nil, retainedOriginal: true)
        #expect(RecordingFinishPresentationPolicy.plan(for: completion)
                == .saveOriginalUnchanged(url, reason: "the recording did not pass validation"))
    }

    @Test func retainedErrorCarriesItsFileAndOnlyItsOwnKind() {
        let retained = CameraRetainedRecordingError(originalURL: url, reason: ValidationFailure.failed)
        #expect(CameraRetainedRecordingError.retainedURL(from: retained) == url)
        #expect(CameraRetainedRecordingError.retainedURL(from: ValidationFailure.failed) == nil)
        #expect(retained.originalURL == url)
    }

    @Test func retainedErrorDescribesItselfWithTheReason() {
        let retained = CameraRetainedRecordingError(originalURL: url, reason: ValidationFailure.failed)
        #expect(retained.errorDescription?.contains("validation failed") == true)
    }
}

private enum ValidationFailure: LocalizedError {
    case failed

    var errorDescription: String? { "validation failed" }
}
