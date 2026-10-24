import Foundation
import Testing

struct VideoImportPresentationTests {
    private let url = URL(fileURLWithPath: "/owned/clip_import_test.mov")

    @Test func renderingRequiresAFileAnExplicitStockAndAButtonAction() {
        var state = VideoImportPresentation()
        #expect(!state.canRender)
        state.selectStock("5219")
        #expect(state.selectedStockID == nil)
        let token = state.begin()
        #expect(state.isLoading && !state.canRender)
        #expect(state.validating(token))
        #expect(state.accept(url: url, token: token))
        #expect(!state.canRender)
        state.selectStock("5219")
        #expect(state.canRender && state.selectedURL == url)
        // Merely selecting a stock does not submit or relinquish the file.
        #expect(state.phase == .ready)
        #expect(state.submitted() == url)
        #expect(!state.canRender && state.selectedURL == nil)
    }

    @Test func cancelledTransferCannotRestoreASelection() {
        var state = VideoImportPresentation()
        let token = state.begin()
        state.reset()
        #expect(!state.validating(token))
        #expect(!state.accept(url: url, token: token))
        state.fail("Late failure", token: token)
        #expect(state.errorMessage == nil && state.selectedURL == nil)
    }

    @Test func replacingAFileInvalidatesTheOldTransferAndStock() {
        var state = VideoImportPresentation()
        let old = state.begin()
        #expect(state.accept(url: url, token: old))
        state.selectStock("5219")
        let current = state.begin()
        #expect(current != old)
        #expect(state.selectedURL == nil && state.selectedStockID == nil)
        #expect(!state.accept(url: url, token: old))
        #expect(state.accept(url: url, token: current))
        #expect(!state.canRender)
    }

    @Test func failedEnqueueRetainsTheSelectedFileForRetry() {
        var state = VideoImportPresentation()
        let token = state.begin()
        #expect(state.accept(url: url, token: token))
        state.selectStock("5219")
        state.enqueueFailed("Could not save the queue.")
        #expect(state.canRender)
        #expect(state.selectedURL == url && state.selectedStockID == "5219")
        #expect(state.errorMessage == "Could not save the queue.")
    }

    @Test func unsupportedSelectionCannotBeRendered() {
        var state = VideoImportPresentation()
        let token = state.begin()
        state.fail("Choose an Apple Log 2 video.", token: token)
        state.selectStock("5219")
        #expect(!state.canRender && state.selectedURL == nil)
        #expect(state.errorMessage == "Choose an Apple Log 2 video.")
    }

    @Test func pickerUsesFileTransferWithoutAnInAppMediaPreview() throws {
        let root = TestRepository.root.appendingPathComponent("App/Modules/VideoImport")
        let sheet = try String(contentsOf: root.appendingPathComponent("VideoImportSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("FileRepresentation(importedContentType: .movie)"))
        #expect(sheet.contains("matching: .videos, preferredItemEncoding: .current"))
        #expect(sheet.contains(".cancel()"))
        #expect(sheet.contains("guard token == presentation.generation"))
        #expect(sheet.contains("lease?.transferToQueue()"))
        #expect(!sheet.contains("AVPlayer") && !sheet.contains("VideoPlayer"))
        #expect(!sheet.contains("AVAssetImageGenerator") && !sheet.contains("StockCarousel"))
        #expect(!sheet.contains("loadTransferable(type: Data.self)"))
        #expect(!sheet.contains("PHAsset") && !sheet.contains("requestAuthorization"))
    }
}
