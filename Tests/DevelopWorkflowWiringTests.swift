import Foundation
import Testing

/// Cross-owner source contracts, not gesture or media-render evidence. The
/// behavioral model/renderer suites exercise those separate boundaries.
@Suite("Develop workflow entry-point wiring")
struct DevelopWorkflowWiringTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func developLabelsStayWithinTwoWords() throws {
        let files = ["DevelopPreview.swift", "DevelopResultsPager.swift", "DevelopMediaHelp.swift"]
        let pattern = #"(?:Text|Button|Label|ProgressView|readout|resultActionLabel|LabeledContent|navigationTitle)\("([^"\n]*)"#
        let labels = try NSRegularExpression(pattern: pattern)
        let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        for file in files {
            let text = try source("App/Modules/VideoImport/" + file)
            let range = NSRange(text.startIndex..., in: text)
            for match in labels.matches(in: text, range: range) {
                let label = (text as NSString).substring(with: match.range(at: 1))
                let literal = interpolation.stringByReplacingMatches(in: label,
                    range: NSRange(label.startIndex..., in: label), withTemplate: "0")
                #expect(literal.split(whereSeparator: \.isWhitespace).count <= 2,
                        "\(file): \(label)")
            }
        }
    }

    @Test func importPreviewAndRenderFailuresShowAnInlineReason() throws {
        let preview = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(preview.contains("Text(DevelopWorkflowPresentation.issueSummary(issue))"))
        #expect(preview.contains("Text(DevelopWorkflowPresentation.issueSummary(failure))"))
        #expect(preview.contains("develop.error.summary"))
        #expect(preview.contains("develop.preview.issue"))
        #expect(preview.contains("DevelopMediaHelp(refusal: model.errorMessage"))
        #expect(preview.contains("Text(failure ??"), "Full preview diagnostics remain in Details")
        let results = try source("App/Modules/VideoImport/DevelopResultsPager.swift")
        #expect(results.contains("Text(DevelopWorkflowPresentation.issueSummary(issue))"))
        #expect(results.contains("develop.result.issue"))
        #expect(results.contains("Text(job?.errorMessage"))
    }

    @Test func previewUsesAvailableSpaceInsteadOfSmallFixedCards() throws {
        for file in ["DevelopPreview.swift", "DevelopResultsPager.swift"] {
            let text = try source("App/Modules/VideoImport/" + file)
            #expect(!text.contains(".frame(height: 210)"))
            #expect(!text.contains(".frame(height: 380)"))
            #expect(!text.contains("ScrollView(.vertical"))
            #expect(text.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        }
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(text.contains("GaugeControl(gauge: $gauge, enlarged: true)"))
        #expect(text.contains("enlarged: true)"))
    }

    @Test func previewRetainsOnlyTheSameOriginalAndBoundsItsWork() throws {
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(text.contains("loadedRequest?.source == source, let frame"))
        #expect(text.contains("if loadedRequest?.source != requested.source"))
        #expect(text.contains("DevelopTransferLoader.load(timeout: .seconds(20))"))
        #expect(text.contains("progress.cancellationHandler = { task.cancel() }"))
        #expect(text.contains(".onDisappear { selectionTask?.cancel() }"))
        #expect(text.contains("fence.accepts(token, cancelled: Task.isCancelled)"))
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
