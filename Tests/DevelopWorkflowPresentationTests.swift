import CoreGraphics
import Foundation
import Testing

@Suite("Develop workflow presentation")
struct DevelopWorkflowPresentationTests {
    @Test func singleAndBatchUseTheSameUnqueuedReviewStage() {
        for count in [1, 2, 12] {
            #expect(DevelopWorkflowPresentation.stage(loading: false, active: false,
                                                     sourceCount: count, resultCount: 0) == .review)
        }
        #expect(DevelopWorkflowPresentation.stage(loading: false, active: false,
                                                 sourceCount: 0, resultCount: 0) == .chooser)
    }

    @Test func acceptedJobsAndPartialAcceptanceKeepResultsDiscoverable() {
        #expect(DevelopWorkflowPresentation.stage(loading: true, active: false,
                                                 sourceCount: 3, resultCount: 0) == .loading)
        #expect(DevelopWorkflowPresentation.stage(loading: false, active: true,
                                                 sourceCount: 1, resultCount: 2) == .rendering)
        #expect(DevelopWorkflowPresentation.stage(loading: false, active: false,
                                                 sourceCount: 1, resultCount: 2) == .results)
        #expect(DevelopWorkflowPresentation.stage(loading: false, active: false,
                                                 sourceCount: 0, resultCount: 2) == .results)
    }

    @Test func resultsPreserveSelectionOrderAndMissingSlots() {
        let first = job("one.dng")
        let second = job("two.mov")
        let missing = UUID()
        let presented = DevelopWorkflowPresentation.orderedJobs(ids: [second.id, missing, first.id],
                                                                 jobs: [first, second])
        #expect(presented.count == 3)
        #expect(presented[0]?.id == second.id)
        #expect(presented[1] == nil)
        #expect(presented[2]?.id == first.id)
    }

    @Test func savedLabelsRequireConfirmedOutputDelivery() {
        var item = job("one.mov")
        item.outputSavedToPhotos = true
        for status in [RenderJob.JobStatus.pending, .processing, .failed, .awaitingStock] {
            item.status = status
            #expect(DevelopWorkflowPresentation.deliveryLabel(item) != "Saved")
        }
        item.status = .completed
        item.sourceSavedToPhotos = true
        for confirmed in [Bool?.none, .some(false)] {
            item.outputSavedToPhotos = confirmed
            #expect(DevelopWorkflowPresentation.deliveryLabel(item) == "Local only")
        }
        item.outputSavedToPhotos = true
        #expect(DevelopWorkflowPresentation.deliveryLabel(item) == "Saved")
    }

    @Test func issueSummaryShowsTheReasonInsteadOfJustAnInfoIcon() {
        #expect(DevelopWorkflowPresentation.issueSummary("Unsupported video format.") == "Unsupported video format.")
        #expect(DevelopWorkflowPresentation.issueSummary("  Preview timeout\nDecoder diagnostics  ") == "Preview timeout")
        #expect(DevelopWorkflowPresentation.issueSummary(" \n ") == "Unavailable")
    }

    @Test func issueSummaryBoundsLongDiagnosticsWithoutChangingTheOriginal() {
        let message = String(repeating: "Decoder could not read this source. ", count: 12)
        let summary = DevelopWorkflowPresentation.issueSummary(message)
        #expect(summary.count <= 121)
        #expect(summary.hasSuffix("…"))
        #expect(summary.hasPrefix("Decoder could not read this source."))
        #expect(message.count > summary.count)
        let unbroken = DevelopWorkflowPresentation.issueSummary(String(repeating: "é", count: 150))
        #expect(unbroken.count == 121)
        #expect(unbroken.hasSuffix("…"))
    }

    @Test func exposureIsSignedAndMissingMetadataIsNeverAssumedNeutral() {
        #expect(DevelopWorkflowPresentation.exposure(1.3) == "+1.3 EV")
        #expect(DevelopWorkflowPresentation.exposure(-2) == "-2.0 EV")
        #expect(DevelopWorkflowPresentation.exposure(0) == "+0.0 EV")
        for missing in [Double?.none, .some(.nan), .some(.infinity), .some(-.infinity)] {
            #expect(DevelopWorkflowPresentation.exposure(missing) == "—")
        }
        #expect(DevelopWorkflowPresentation.captureRating(640) == "ISO 640")
        for missing in [Float?.none, .some(.nan), .some(.infinity), .some(0), .some(-1)] {
            #expect(DevelopWorkflowPresentation.captureRating(missing) == "—")
        }
    }

    @Test func previewFenceRejectsCancelledAndSupersededCompletions() {
        var fence = DevelopPreviewFence()
        let first = fence.begin()
        #expect(fence.accepts(first, cancelled: false))
        #expect(!fence.accepts(first, cancelled: true))
        let second = fence.begin()
        #expect(!fence.accepts(first, cancelled: false))
        #expect(fence.accepts(second, cancelled: false))
        // The same recipe can be requested again; an old actor completion still
        // must not overwrite the new selection's state.
        let third = fence.begin()
        #expect(!fence.accepts(second, cancelled: false))
        #expect(fence.accepts(third, cancelled: false))
    }

    @Test func colorRecipeInputsInvalidateWithoutRestartingForGaugeChanges() {
        let configuration = stock()
        let url = URL(fileURLWithPath: "/fixture/source.dng")
        func recipe(url overrideURL: URL? = nil, photo: Bool = true, crop: Double = 1,
                    stock overrideStock: FilmStockConfig? = nil, gauge: PrintGauge = .thirtyFiveMillimetre,
                    pushPull: PushPullExposure = .neutral) -> DevelopPreviewRecipe {
            DevelopPreviewRecipe(url: overrideURL ?? url, isPhoto: photo, cropZoom: crop,
                                 stock: overrideStock ?? configuration, gauge: gauge, pushPull: pushPull)
        }
        let shown = recipe()
        #expect(shown != recipe(url: URL(fileURLWithPath: "/fixture/next.dng")))
        #expect(shown != recipe(photo: false))
        #expect(shown != recipe(crop: 1.5))
        #expect(shown == recipe(gauge: .sixteenMillimetre), "Gauge changes must not restart a colour-only preview")
        #expect(shown != recipe(pushPull: .manual(.pullOne)))
        var changedStock = configuration
        changedStock.outputContrast = 0.9
        #expect(shown != recipe(stock: changedStock), "A reused stock ID must not reuse stale pixels")
        #expect(shown.stock.outputContrast == 1, "The render request is a value snapshot")
        var effectsOnly = configuration
        effectsOnly.printGauge = .eightMillimetre
        effectsOnly.diffusion = .disabled
        effectsOnly.stillHalationScale = 0
        #expect(shown == recipe(stock: effectsOnly), "Export-only effects must not restart the preview")
        #expect(shown == recipe())
    }

    @Test func redevelopRemainsEnabledForAMixedBatchWithOneRetainedVideo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("retained.mov")
        let emptyURL = directory.appendingPathComponent("empty.dng")
        try Data([1]).write(to: videoURL)
        try Data().write(to: emptyURL)
        var retained = RenderJob(sourceURL: videoURL, stockId: "test", iso: 400)
        retained.isImportedVideo = true
        retained.retainsDevelopmentSource = true
        retained.status = .completed
        var empty = RenderJob(sourceURL: emptyURL, stockId: "test", iso: 400)
        empty.isPhoto = true
        let absent = RenderJob(sourceURL: directory.appendingPathComponent("gone.mov"), stockId: "test", iso: 400)
        let mixed = DevelopWorkflowPresentation.redevelopment(jobs: [empty, retained, absent], requestedCount: 4)
        #expect(mixed.isEnabled)
        #expect(mixed.availableIDs == [retained.id])
        #expect(mixed.missingCount == 3, "Missing queue entries count as unavailable, not successful results")
        try FileManager.default.removeItem(at: videoURL)
        let gone = DevelopWorkflowPresentation.redevelopment(jobs: [retained, empty, absent], requestedCount: 4)
        #expect(!gone.isEnabled)
        #expect(gone.availableIDs.isEmpty)
        #expect(gone.missingCount == 4)
    }

    @Test func zoomCannotBecomeInfiniteOrLoseTheImageBelowFitSize() {
        #expect(DevelopWorkflowPresentation.zoom(0.2) == 1)
        #expect(DevelopWorkflowPresentation.zoom(3) == 3)
        #expect(DevelopWorkflowPresentation.zoom(20) == 8)
        #expect(DevelopWorkflowPresentation.zoom(.nan) == 1)
        #expect(DevelopWorkflowPresentation.zoom(.infinity) == 1)
    }

    private func job(_ name: String) -> RenderJob {
        RenderJob(sourceURL: URL(fileURLWithPath: "/fixture/" + name), stockId: "test", iso: 400)
    }

    private func stock() -> FilmStockConfig {
        FilmStockConfig(stockId: "test", displayName: "Test", category: .video, lutName: "test.cube",
                        halationStrength: 0.2, glowStrength: 0.1, grainSize: 1, defaultISO: 400)
    }
}
