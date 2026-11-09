import Foundation
import Testing

/// Cross-owner source contracts, not gesture or media-render evidence. The
/// behavioral model/renderer suites exercise those separate boundaries.
@Suite("Develop workflow entry-point wiring")
struct DevelopWorkflowWiringTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func queueBulkActionReturnsToReviewInsteadOfRenderingImmediately() throws {
        let content = try source("App/ContentView.swift")
        let start = try #require(content.range(of: "onBulkRedevelop: { ids in"))
        let tail = content[start.upperBound...]
        let end = try #require(tail.range(of: "\n            }"))
        let action = tail[..<end.lowerBound]
        #expect(action.contains("reviewDevelops("))
        #expect(!action.contains("redevelopPhotos("))
        #expect(!action.contains("redevelopJobs("))
        #expect(content.contains("await developModel.adoptExistingJobs(jobs)"))
    }

    @Test func cameraBarAndPanelUseTheSharedSubmissionOwner() throws {
        let content = try source("App/ContentView.swift")
        #expect(content.contains("developCanRender: developModel.canDevelop(stock: selectedStock)"))
        #expect(content.contains("developModel.develop(stock: stock, iso: currentISO, gauge: developGauge"))
        #expect(!content.contains("developModel.render("))
        #expect(!content.contains("developModel.adoptExistingPhoto("))
        #expect(content.contains("developModel.hasActiveRenders"))
    }

    @Test func importedVideoCanExposeRedevelopmentWithoutPlaybackOrSharing() throws {
        let card = try source("App/Modules/RenderQueue/QueueReceiptViews.swift")
        #expect(card.contains("job.receiptActions.playLocal || job.receiptActions.shareLocal || redevelop != nil"))
        #expect(card.contains("if job.hasRedevelopableSource, let redevelop"))
        #expect(card.contains("\"queue.redevelopVideo\""))
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(sheet.contains("redevelop: canReviewOriginal(job) ? { onRedevelop(job) } : nil"))
        #expect(sheet.contains("job.originalOnly != true && job.hasRedevelopableSource"))
        #expect(sheet.contains("if isSelecting, canReviewOriginal(latestRender)"))
    }
}
