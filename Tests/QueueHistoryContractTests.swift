import Foundation
import Testing

/// Source contracts for the compact History sheet's presentation-only rules.
///
/// `QueueSheetView`, `QueueContactSheet` and the History preview helpers are
/// SwiftUI/UIKit views that the macOS test target does not compile. These tests
/// pin the behaviours that would otherwise regress silently: failed filtering,
/// hide-only clearing, the three-page preview window, display-sized poster
/// decoding, and the inert delete stub.
@Suite("History compact surface contracts")
struct QueueHistoryContractTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func section(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(text.range(of: startMarker))
        let end = try #require(text.range(of: endMarker, range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    @Test func failedCountAndFilterOnlyCoverVisibleFailedImages() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let summary = try source("App/Modules/RenderQueue/QueueContactSheet.swift")
        let receipts = try section(sheet, from: "private var historyReceipts",
                                   to: "private var shownReceipts")
        #expect(receipts.contains("showsFailedOnly ? images.filter { $0.status == .failed } : images"))
        #expect(receipts.contains("let mode: QueueHistoryMode = showsFailedOnly ? .visible : historyMode"),
                "The failed view always reads visible history")
        #expect(summary.contains("failed = finished.filter { $0.status == .failed && !hiddenIDs.contains($0.id) }.count"),
                "Hidden failures do not inflate the header count")

        let controls = try section(sheet, from: "private var failedControls", to: "private func toggleFailedFilter")
        #expect(controls.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
        #expect(controls.contains("accessibilityLabel(\"Back to all images\")"))
        #expect(controls.contains("queue.failedBack"))
        #expect(controls.contains("Button(\"Clear all\")"))
        #expect(sheet.contains("formatter.dateFormat = \"MM/dd-HH:mm\""),
                "Failed rows state the recorded moment compactly")
        #expect(sheet.contains("if isExpanded, !showsFailedOnly { notices }"),
                "Queue notices and work sections stay out of the failed view")
        #expect(sheet.contains("showsFailedOnly = false"), "The eye toggle returns to all images")
    }

    @Test func clearingFailuresHidesIdentifiersWithoutTouchingJobsOrMedia() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let clear = try section(sheet, from: "private func clearFailed", to: "private func failedTimestamp")
        #expect(clear.contains("let currentFailures = Set(viewModel.jobs.filter { $0.status == .failed }.map(\\.id))"))
        #expect(clear.contains("let doomed = ids.intersection(currentFailures)"))
        #expect(clear.contains("for id in doomed { viewModel.historyVisibility.hide(id) }"))
        #expect(clear.contains("preparePreviewForRemoval(of: doomed)"),
                "A batch clear continues the open preview before the rows leave")
        for forbidden in ["viewModel.remove(", "removeItem", "FileManager", "PHAsset", "PhotosPicker",
                          "outputURL", ".status = .", "sourceURL ="] {
            #expect(!clear.contains(forbidden), "Clearing failures must not touch media or jobs: \(forbidden)")
        }
    }

    @Test func inlinePreviewKeepsAtMostThreePagesActiveAndReleasesInactivePixels() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let inline = try source("App/Modules/RenderQueue/HistoryInlinePreview.swift")
        let zoom = try source("App/Modules/RenderQueue/HistoryZoomableImage.swift")

        #expect(sheet.contains("let start = max(index - 1, 0)"))
        #expect(sheet.contains("let end = min(index + 2, images.count)"))
        #expect(sheet.contains("let activeIDs = Set(images[start..<end].map(\\.id))"))
        #expect(sheet.contains("HistoryInlinePreview(job: job, isActive: activeIDs.contains(job.id))"))
        #expect(sheet.contains("TabView(selection: $previewJobID)"))
        #expect(sheet.contains(".tabViewStyle(.page(indexDisplayMode: .never))"))
        #expect(sheet.contains("queue.previewSizeToggle"))
        #expect(sheet.contains("private var previewFocused = false"))
        let surface = try section(sheet, from: "private var surface", to: ".sheet(item: $shareTarget)")
        let preview = try #require(surface.range(of: "inlinePreview"))
        let grid = try #require(surface.range(of: "historySection"))
        #expect(preview.lowerBound < grid.lowerBound, "The pager sits above the same contact sheet")

        #expect(inline.contains("guard isActive, job.permitsReceiptPreview else {"))
        #expect(inline.contains("image = nil"), "An inactive page drops its decoded image")
        #expect(inline.contains(".onDisappear { image = nil }"))
        #expect(inline.contains("kCGImageSourceThumbnailMaxPixelSize: 2048"),
                "Full-photo previews are still bounded")
        let frame = try source("App/Modules/RenderQueue/ContactPreviewFrame.swift")
        #expect(inline.contains("ContactPreviewFrame("))
        #expect(frame.contains("formatter.dateFormat = \"yyyy-MM-dd HH:mm\""),
                "Printed metadata uses a 24-hour recorded time")
        #expect(zoom.contains("maximumZoomScale = 6"))
        #expect(zoom.contains("func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }"))
        for view in [inline, zoom] {
            #expect(!view.contains("import Photos"))
            #expect(!view.contains("PHAsset"))
            #expect(!view.contains("PhotosPicker"))
        }
    }

    @Test func historySeparatesReceiptStillsFromImportedMovieAccess() throws {
        let inline = try source("App/Modules/RenderQueue/HistoryInlinePreview.swift")
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let cards = try source("App/Modules/RenderQueue/QueueReceiptViews.swift")
        #expect(inline.contains("guard isActive, job.permitsReceiptPreview else {"))
        #expect(inline.contains("if job.permitsLocalMedia, let url = job.retainedOutputURL {"),
                "Allowing a saved still must not enable full imported-movie reads")
        #expect(cards.contains("if job.permitsReceiptPreview, let data = job.receipt?.thumbnailJPEG"))
        #expect(sheet.contains("job.permitsReceiptPreview && job.receipt?.thumbnailJPEG != nil"))
    }

    @Test func gridDecodesDisplaySizedPostersAndReleasesThem() throws {
        let thumbnail = try source("App/Modules/RenderQueue/HistoryGridThumbnail.swift")
        let service = try source("App/Modules/RenderQueue/RenderReceiptService.swift")
        let views = try source("App/Modules/RenderQueue/QueueReceiptViews.swift")

        #expect(service.contains("static func gridPoster(from jpeg: Data) -> CGImage?"))
        #expect(service.contains("kCGImageSourceThumbnailMaxPixelSize: 320"))
        #expect(thumbnail.contains("Task.detached(priority: .utility)"))
        #expect(thumbnail.contains("RenderReceiptService.gridPoster(from: jpeg)"))
        #expect(thumbnail.contains("guard !Task.isCancelled else { return }"))
        #expect(thumbnail.contains(".onDisappear { image = nil }"))
        #expect(views.contains("HistoryGridThumbnail(jpeg: data)"))

        let poster = try section(views, from: "private var contactPoster", to: "private var contactStatusMark")
        let strip = try #require(poster.range(of: "if !job.presentsAsPhoto {"))
        let border = try #require(poster.range(of: "QueueFrameStripBorder()"))
        #expect(strip.lowerBound < border.lowerBound, "The video strip is the media cue, never the poster data")
        #expect(!poster.contains("thumbnailJPEG"), "The cell does not inspect image bytes to choose a type")
    }

    @Test func deletionRemainsAnInertStubWithThreeScopes() throws {
        let scope = try source("App/Modules/RenderQueue/HistoryDeletionScope.swift")
        let deletion = try source("App/Modules/RenderQueue/HistoryDeletionSheet.swift")
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")

        #expect(scope.contains("case olderThan30Days"))
        #expect(scope.contains("case olderThan7Days"))
        #expect(scope.contains("case all"))
        #expect(scope.contains("case .olderThan30Days: return 30"))
        #expect(scope.contains("case .olderThan7Days: return 7"))
        #expect(deletion.contains("Content won’t be deleted from Photos."))
        #expect(deletion.contains("onRequest(selectedScope)"), "The stub only reports the chosen scope")
        #expect(deletion.contains("queue.historyDelete.confirm"))
        #expect(sheet.contains("HistoryDeletionSheet { _ in"))
        #expect(sheet.contains("Deletion is not enabled yet. No images were deleted."))
        #expect(sheet.contains("queue.deleteImages"))
        for text in [scope, deletion] {
            for forbidden in ["removeItem", "FileManager", "PHAsset", "import Photos", "CreatePhotoLibrary"] {
                #expect(!text.contains(forbidden), "The delete stub cannot remove content: \(forbidden)")
            }
        }
        #expect(!sheet.contains("viewModel.remove(jobId: id)"), "Delete never loops over queue removal")
    }
}
