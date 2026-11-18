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
        // Help contains explanatory paragraphs, not compact action labels.
        let files = ["DevelopPreview.swift", "DevelopResultsPager.swift"]
        let pattern = #"(?<![A-Za-z])(?:Text|Button|Label|ProgressView|readout|resultActionLabel|LabeledContent|navigationTitle)\("([^"\n]*)"#
        let labels = try NSRegularExpression(pattern: pattern)
        let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        for file in files {
            let text = try source("App/Modules/VideoImport/" + file)
            let range = NSRange(text.startIndex..., in: text)
            for match in labels.matches(in: text, range: range) {
                let label = (text as NSString).substring(with: match.range(at: 1))
                let literal = interpolation.stringByReplacingMatches(in: label,
                    range: NSRange(label.startIndex..., in: label), withTemplate: "0")
                // The chooser prompt is owner-approved explanatory copy, not an action label.
                if literal == "Choose what to develop" { continue }
                #expect(literal.split(whereSeparator: \.isWhitespace).count <= 2,
                        "\(file): \(label)")
            }
        }
    }

    @Test func onlyThePhotoPickerNamesItsLibraryForPairedRawIdentity() throws {
        let preview = try source("App/Modules/VideoImport/DevelopPreview.swift")
        let videoStart = try #require(preview.range(of: "private var videoPicker: some View"))
        let photoStart = try #require(preview.range(of: "private var photoPicker: some View"))
        let stagingStart = try #require(preview.range(of: "private func stageClips("))
        let video = preview[videoStart.lowerBound..<photoStart.lowerBound]
        let photo = preview[photoStart.lowerBound..<stagingStart.lowerBound]
        #expect(photo.contains("preferredItemEncoding: .current, photoLibrary: .shared()"))
        #expect(!video.contains("photoLibrary:"))
    }

    @Test func pairedRawLookupAuthorizesBeforeTimingTheSelectedResourceTransfer() throws {
        let picker = try source("App/Modules/VideoImport/DevelopVideoPicker.swift")
        let loaderStart = try #require(picker.range(of: "enum DevelopPhotoLibraryRaw {"))
        let authorization = try #require(picker.range(of: "try await PhotoLibraryRawRequest.authorizeRead()",
            range: loaderStart.upperBound..<picker.endIndex))
        let transfer = try #require(picker.range(of: "try await DevelopTransferLoader.load(",
            range: loaderStart.upperBound..<picker.endIndex))
        #expect(authorization.lowerBound < transfer.lowerBound,
                "Time spent deciding a Photos permission is not a failed network transfer")
        #expect(picker.contains("guard PhotoImportService.shouldRetryFromLibrary(after: directFailure)"))
        #expect(picker.contains("PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)"))
        #expect(picker.contains("manager.requestData(for: resource, options: options)"))
        #expect(picker.contains("manager.cancelDataRequest(installed)"))
        #expect(picker.contains("try await PhotoImportService.validateRaw(at: file)"))
        #expect(picker.contains("VideoImportService.copyToOwnedStorage("))
        #expect(picker.contains("DevelopVideoModel.DevelopPhotoTransfer("))
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

    @Test func reviewKeepsTheSharedRecipePickerOpenBelowTheSource() throws {
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(text.contains("CompactStockPicker("))
        #expect(text.contains("gauge: $gauge"))
        #expect(text.contains("manualStops: $pushPullStops"))
        #expect(text.contains("resolvedPushPull: resolvedPushPull"))
        #expect(!text.contains("StockSamplePreview("), "The staged source is the review preview")
        #expect(text.contains("ScrollView"), "Short screens must retain access to every recipe control")
        let picker = try source("App/Modules/FilmStockLibrary/CompactStockPicker.swift")
        #expect(picker.contains("GaugeControl(gauge: $gauge, enlarged: true)"))
        #expect(picker.contains("PushPullControl(resolved: resolvedPushPull"))
        #expect(text.contains("model.develop(stock: stock, iso: stock.defaultISO, gauge: gauge, pushPull: resolvedPushPull,"))
        #expect(text.contains("whiteBalance: whiteBalance)"))
    }

    @Test func whiteBalanceUsesTheReviewBindingForPreviewSubmissionAndRecall() throws {
        let preview = try source("App/Modules/VideoImport/DevelopPreview.swift")
        let content = try source("App/ContentView.swift")
        let picker = try source("App/Modules/FilmStockLibrary/CompactStockPicker.swift")
        let control = try source("App/Modules/VideoImport/DevelopWhiteBalanceControl.swift")
        #expect(preview.contains("whiteBalance: $whiteBalance"))
        #expect(preview.contains("whiteBalance: recipe.whiteBalance"))
        #expect(preview.contains("whiteBalance = first.developmentWhiteBalance ?? .neutral"))
        #expect(content.contains("whiteBalance: $developWhiteBalance"))
        #expect(content.contains("whiteBalance: developWhiteBalance"))
        #expect(content.contains("developWhiteBalance = first.developmentWhiteBalance ?? .neutral"))
        #expect(picker.contains("DevelopWhiteBalanceControl(value: whiteBalance"))
        #expect(control.contains("Slider(value: sliderValue"))
        #expect(control.contains(".presentationCompactAdaptation(.popover)"))
        #expect(control.contains("Relative correction, not the camera's recorded white balance."))
    }

    @Test func returnToVideoIsLimitedToAnEmptyChooser() throws {
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        let start = try #require(text.range(of: "private var labHeader: some View"))
        let tail = text[start.upperBound...]
        let end = try #require(tail.range(of: "private var stockPicker: some View"))
        let header = tail[..<end.lowerBound]
        let chooserExit = header.contains("if stage == .chooser {\n                returnToVideoButton")
        #expect(chooserExit, "Returning to Video is offered only when no staged batch can be discarded")
        #expect(header.contains("Button(action: startOver)"))
        #expect(header.contains("develop.bulkCancel"))
    }

    @Test func reviewAndResultsUseOneBlackContactFrame() throws {
        let preview = try source("App/Modules/VideoImport/DevelopPreview.swift")
        let results = try source("App/Modules/VideoImport/DevelopResultsPager.swift")
        let history = try source("App/Modules/RenderQueue/HistoryInlinePreview.swift")
        let frame = try source("App/Modules/RenderQueue/ContactPreviewFrame.swift")
        for surface in [preview, results, history] {
            #expect(surface.contains("ContactPreviewFrame("))
        }
        #expect(!preview.contains(".background(.black.opacity(0.68)"), "Metadata must not overlay the source")
        #expect(frame.contains(".black"))
        #expect(frame.contains("rotationEffect"), "Side printing is vertical")
        #expect(frame.contains("QueueFrameStripBorder()"))
        #expect(frame.contains("private let printColor = Color.white.opacity(0.85)"))
        #expect(!results.contains("struct DevelopFrameStrip"))
        #expect(results.contains("CAPTURE ISO"))
        #expect(results.contains("RENDER ISO"), "Selected ISO must not masquerade as capture ISO")
    }

    @Test func redevelopmentUsesRetainedSourcesAndThePriorRecipe() throws {
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(text.contains("await model.adoptExistingJobs(jobs)"))
        #expect(text.contains("first.printGauge"))
        #expect(text.contains("first.pushPull?.stops"))
        #expect(text.contains("first.stockId"))
        #expect(text.contains("develop.redevelop"))
        #expect(text.contains("PhotosLibraryOpener.failureMessage"))
    }

    @Test func localResultFallbackStartsAtZeroAndNeverReadsPhotos() throws {
        let text = try source("App/Modules/VideoImport/DevelopPreview.swift")
        #expect(!text.contains("CMTime(seconds: 1,"))
        #expect(text.contains("url.isFileURL"))
        let renderer = try source("App/Modules/VideoImport/DevelopFramePreviewRenderer.swift")
        #expect(renderer.contains("reader.timeRange = CMTimeRange(start: .zero"))
        #expect(renderer.contains("track.load(.preferredTransform)"))
        for file in ["DevelopPreview.swift", "DevelopResultsPager.swift"] {
            let code = try source("App/Modules/VideoImport/" + file)
            #expect(!code.contains("PHAsset"))
            #expect(!code.contains("PHImageManager"))
        }
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
        #expect(content.contains("developModel.develop(stock: stock, iso: stock.defaultISO, gauge: developGauge"))
        #expect(!content.contains("developModel.render("))
        #expect(!content.contains("developModel.adoptExistingPhoto("))
        #expect(content.contains("developModel.hasActiveRenders"))
    }

    @Test func importedVideoCanExposeRedevelopmentWithoutPlaybackOrSharing() throws {
        let card = try source("App/Modules/RenderQueue/QueueReceiptViews.swift")
        #expect(card.contains("Menu { localActions }"))
        #expect(card.contains("job.receiptActions.playLocal || job.receiptActions.shareLocal"))
        #expect(card.contains("redevelopmentAction"))
        #expect(card.contains("if job.hasRedevelopableSource, let redevelop"))
        #expect(card.contains("\"queue.redevelopVideo\""))
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(sheet.contains("redevelop: canReviewOriginal(job) ? { onRedevelop(job) } : nil"))
        #expect(sheet.contains("job.originalOnly != true && job.hasRedevelopableSource"))
        #expect(sheet.contains("if isSelecting, canReviewOriginal(job)"))
    }

    /// Native rows replace the retired action grid without changing video
    /// permissions or the retained-original bulk review route.
    @Test func contactSheetUsesVerticalActionsAndKeepsTheBulkDevelopPath() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let actions = try source("App/Modules/RenderQueue/QueueContactSheet.swift")
        #expect(sheet.contains(".contextMenu { receiptActions(job) }"))
        #expect(sheet.contains(".accessibilityActions { receiptActions(job) }"))
        #expect(sheet.contains("Label(\"Open Photos\", systemImage: \"photo.on.rectangle\")"))
        #expect(sheet.contains("QueueReceiptPresentation.photosActionID + \".video\""))
        #expect(sheet.contains("queue.redevelopPhoto"))
        #expect(!sheet.contains("queue.redevelopVideo"), "Video menu preserves Photos rather than a new per-video Develop action")
        #expect(!sheet.contains("selectedJobID"))
        #expect(!actions.contains("QueueReceiptActionOverlay"))
        #expect(sheet.contains("onBulkRedevelop(selection)"))
        #expect(sheet.contains("queue.bulkRedevelop"))
        #expect(!sheet.contains("redevelopJobs("), "Bulk re-develop hands off to Develop review")
    }

}
