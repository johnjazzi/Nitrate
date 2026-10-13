import Foundation
import Testing

struct CameraStatusPresentationTests {
    private func status(outstanding: Int = 0, pending: Int = 0, processing: Bool = false,
                        failed: Int = 0, error: String? = nil, completed: Bool = false,
                        saved: Bool? = nil) -> CameraStatusPresentation {
        CameraStatusPresentation(outstandingCount: outstanding, pendingCount: pending,
                                 isProcessing: processing, failedCount: failed, errorMessage: error,
                                 latestResultCompleted: completed, latestResultSavedToPhotos: saved)
    }

    @Test func idleStillShowsQueueAffordance() {
        let value = status()
        #expect(value.label == "QUEUE")
        #expect(value.countText == nil)
        #expect(!value.isSaved)
        #expect(!value.hasError)
    }

    @Test func liveWorkAndWaitingHaveCountsWithoutInventedProgress() {
        let working = status(outstanding: 3, pending: 2, processing: true)
        #expect(working.label == "RENDERING")
        #expect(working.countText == "3")
        #expect(working.accessibilityDescription.contains("3 videos outstanding, 2 waiting"))
        #expect(status(outstanding: 1, pending: 1).label == "WAITING")
        #expect(status(processing: true, completed: true, saved: true).label == "RENDERING")
    }

    @Test func renderingMotionOnlyRunsWhileProcessingWithoutReducedMotion() {
        let rendering = status(outstanding: 3, pending: 2, processing: true)
        #expect(rendering.shouldAnimateRendering(reduceMotion: false))
        #expect(!rendering.shouldAnimateRendering(reduceMotion: true))
        #expect(rendering.accessibilityDescription.hasPrefix("Rendering..."))
        let waiting = status(outstanding: 2, pending: 2)
        #expect(!waiting.shouldAnimateRendering(reduceMotion: false))
        #expect(waiting.accessibilityDescription.hasPrefix("Waiting."))
        #expect(!status().shouldAnimateRendering(reduceMotion: false))
        #expect(!status(failed: 1).shouldAnimateRendering(reduceMotion: false))
        #expect(!status(completed: true, saved: true).shouldAnimateRendering(reduceMotion: false))
        #expect(status(processing: true, failed: 1).shouldAnimateRendering(reduceMotion: false))
    }

    @Test func renderingTransitionsThroughWaitingBeforeConfirmedPhotosSave() {
        let rendering = status(outstanding: 2, pending: 1, processing: true)
        #expect(rendering.label == "RENDERING")
        #expect(!rendering.isSaved)
        let waiting = status(outstanding: 1, pending: 1, completed: true, saved: true)
        #expect(waiting.label == "WAITING")
        #expect(!waiting.isSaved)
        #expect(!waiting.shouldAnimateRendering(reduceMotion: false))
        let completedOnly = status(completed: true, saved: false)
        #expect(completedOnly.label == "QUEUE")
        #expect(!completedOnly.isSaved)
        let delivered = status(completed: true, saved: true)
        #expect(delivered.label == "SAVED")
        #expect(delivered.isSaved)
        #expect(!delivered.shouldAnimateRendering(reduceMotion: false))
    }

    @Test func visualCountCapDoesNotCapAccessibility() {
        let value = status(outstanding: 123, pending: 122, processing: true)
        #expect(value.countText == "99+")
        #expect(value.accessibilityDescription.contains("123 videos outstanding, 122 waiting"))
        #expect(status(outstanding: 99).countText == "99")
    }

    @Test func failureBadgeSurvivesConcurrentWorkAndNewerSuccess() {
        let busy = status(outstanding: 2, processing: true, failed: 1, error: "Photos save failed")
        #expect(busy.label == "RENDERING")
        #expect(busy.hasError)
        #expect(busy.accessibilityDescription.contains("Photos save failed"))
        let failed = status(failed: 1, completed: true, saved: true)
        #expect(failed.label == "FAILED")
        #expect(!failed.isSaved)
        let rendererError = status(error: "Queue could not be loaded", completed: true, saved: true)
        #expect(rendererError.hasError)
        #expect(rendererError.label == "FAILED")
        #expect(rendererError.accessibilityDescription.contains("Queue could not be loaded"))
    }

    @Test func savedRequiresExplicitPhotosDeliveryAndNoOutstandingWork() {
        #expect(status(completed: true, saved: true).isSaved)
        #expect(status(completed: true, saved: true).label == "SAVED")
        #expect(!status(completed: true).isSaved)
        #expect(!status(completed: true, saved: false).isSaved)
        #expect(!status(saved: true).isSaved)
        #expect(!status(outstanding: 1, completed: true, saved: true).isSaved)
    }

    @Test func unknownStorageNeverShowsZeroOrSavedTime() {
        let invalid: [TimeInterval?] = [nil, -.infinity, .infinity, .nan, -1, Double(Int.max)]
        for value in invalid {
            #expect(CameraStatusPresentation.timeText(for: value) == "--:--")
            #expect(CameraStatusPresentation.compactTimeText(for: value) == "--:--")
        }
        #expect(CameraStatusPresentation.timeText(for: 0) == "00:00")
        #expect(CameraStatusPresentation.compactTimeText(for: 59.9) == "00:59")
    }

    @Test func compactHourEstimatePreservesExactAccessibleDuration() {
        #expect(CameraStatusPresentation.compactTimeText(for: 5_039) == "1h23m")
        #expect(CameraStatusPresentation.timeText(for: 5_039) == "1:23:59")
        #expect(CameraStatusPresentation.compactTimeText(for: 359_999) == "99h+")
        #expect(CameraStatusPresentation.compactTimeText(for: 360_000) == "99h+")
        #expect(CameraStatusPresentation.timeText(for: 360_000) == "100:00:00")
    }
}
