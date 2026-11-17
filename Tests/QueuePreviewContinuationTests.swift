import Foundation
import Testing

/// Regression coverage for History's open preview when the displayed receipt
/// order changes underneath it.
///
/// The reported bug: hiding the image being previewed jumped back to the first
/// (newest) contact instead of moving on. The old rule was a bare
/// `previewJobID = ids.first`; these tests pin the continuation rule that
/// replaces it, and the source contracts that keep the sheet using it.
///
/// No jobs, media, persistence, or permissions are involved: the continuation is
/// a pure function over two displayed ID orders.
@Suite("Queue preview continuation")
struct QueuePreviewContinuationTests {
    private let newest = UUID()
    private let second = UUID()
    private let third = UUID()
    private let oldest = UUID()

    /// Newest-first contact-sheet order, matching `QueueHistoryMode.receipts`.
    private var allFour: [UUID] { [newest, second, third, oldest] }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Continuation

    @Test func hidingTheMiddlePreviewContinuesToTheNextContact() {
        let next = QueuePreviewContinuation.selection(
            current: second, oldIDs: allFour, newIDs: [newest, third, oldest])
        #expect(next == third, "Hiding a middle image advances to the row below it, not the first")
    }

    @Test func hidingTheFirstPreviewContinuesToTheSecond() {
        let next = QueuePreviewContinuation.selection(
            current: newest, oldIDs: allFour, newIDs: [second, third, oldest])
        #expect(next == second)
        #expect(next != allFour.first, "The removed page must not resolve back to itself")
    }

    @Test func hidingTheLastPreviewFallsBackToTheNearestPredecessor() {
        let next = QueuePreviewContinuation.selection(
            current: oldest, oldIDs: allFour, newIDs: [newest, second, third])
        #expect(next == third, "At the end of the list the preview steps back one row")
    }

    @Test func hidingTheOnlyPreviewClosesIt() {
        let next = QueuePreviewContinuation.selection(
            current: second, oldIDs: [second], newIDs: [])
        #expect(next == nil, "An emptied display closes the preview instead of showing nothing")
    }

    @Test func hidingAnotherContactPreservesTheOpenPreview() {
        let next = QueuePreviewContinuation.selection(
            current: third, oldIDs: allFour, newIDs: [newest, second, third])
        #expect(next == third, "Hiding a different row leaves the preview exactly where it was")
    }

    @Test func multipleRemovalsSkipPastEveryGap() {
        let next = QueuePreviewContinuation.selection(
            current: second, oldIDs: allFour, newIDs: [newest, oldest])
        #expect(next == oldest, "A batch clear continues to the next surviving row")
    }

    @Test func multipleRemovalsBehindTheLastPreviewStepBackPastEveryGap() {
        let next = QueuePreviewContinuation.selection(
            current: oldest, oldIDs: allFour, newIDs: [newest])
        #expect(next == newest)
        let empty = QueuePreviewContinuation.selection(
            current: oldest, oldIDs: allFour, newIDs: [])
        #expect(empty == nil)
    }

    @Test func reorderedSurvivorsKeepTheCurrentPreview() {
        let next = QueuePreviewContinuation.selection(
            current: third, oldIDs: allFour, newIDs: [oldest, third, second, newest])
        #expect(next == third, "A surviving row stays selected wherever it lands")
    }

    @Test func replacedListFallsBackToTheFirstRow() {
        let next = QueuePreviewContinuation.selection(
            current: second, oldIDs: [newest, second], newIDs: [oldest, third])
        #expect(next == oldest, "The visible/hidden eye flip keeps the previous first-row fallback")
    }

    @Test func closedPreviewStaysClosed() {
        let next = QueuePreviewContinuation.selection(
            current: nil, oldIDs: allFour, newIDs: [newest, second])
        #expect(next == nil, "A hidden-list change never opens a preview by itself")
    }

    @Test func preselectingBeforeRemovalSurvivesTheRemoval() {
        // The sheet picks the successor first, then the row disappears. Running
        // the policy again over the post-removal order must not move it a second
        // time - otherwise the pager would drift by one contact.
        let preselect = QueuePreviewContinuation.selection(
            current: second, oldIDs: allFour, newIDs: [newest, third, oldest])
        #expect(preselect == third)
        let settled = QueuePreviewContinuation.selection(
            current: preselect, oldIDs: allFour, newIDs: [newest, third, oldest])
        #expect(settled == third, "The preselected successor is retained by the follow-up change")
    }

    @Test func unstoredCurrentFallsBackToTheFirstRow() {
        let stranger = UUID()
        let next = QueuePreviewContinuation.selection(
            current: stranger, oldIDs: allFour, newIDs: [newest, second])
        #expect(next == newest)
    }

    // MARK: - Source contracts

    private func section(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(text.range(of: startMarker))
        let end = try #require(text.range(of: endMarker, range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    @Test func sheetContinuesThePreviewInsteadOfJumpingToTheFirstContact() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        #expect(!sheet.contains("previewJobID = ids.first"),
                "The first-row jump is the reported bug and must not come back")
        #expect(sheet.contains("QueuePreviewContinuation.selection(current: previewJobID"),
                "The pager hands the choice to the continuation policy")

        let change = try section(sheet, from: "onChange(of: historyReceipts.map(\\.id))",
                                 to: "onAppear { cameraViewModel.updateFreeSpace() }")
        #expect(change.contains("oldIDs: oldIDs"), "The old order is available to continue from")
        #expect(change.contains("newIDs: newIDs"))
        #expect(change.contains("previewJobID = next"),
                "The policy's answer is the only thing the change handler assigns")
    }

    @Test func hideChoosesTheSuccessorBeforeTheRowIsRemoved() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let harness = try source("App/Modules/RenderQueue/QueueHistoryVisibility.swift")
        #expect(harness.contains("enum QueuePreviewContinuation"),
                "The continuation stays a pure policy in the store's file")

        let toggle = try section(sheet, from: "private func toggleHidden",
                                 to: "private func preparePreviewForRemoval")
        let prepare = try #require(toggle.range(of: "preparePreviewForRemoval(of: [job.id])"))
        let flip = try #require(toggle.range(of: "viewModel.historyVisibility."))
        #expect(prepare.lowerBound < flip.lowerBound,
                "Preselecting after the removal cannot beat the pager's first-page snap")

        let helper = try section(sheet, from: "private func preparePreviewForRemoval",
                                 to: "private func toggleSelection")
        #expect(helper.contains("QueuePreviewContinuation.selection("),
                "The helper only times the policy, it does not own a second rule")
        #expect(helper.contains("newIDs: displayed.filter { !doomed.contains($0) }"),
                "The successor is chosen against the order that is about to survive")
    }

    @Test func hidingStillTouchesOnlyVisibility() throws {
        let sheet = try source("App/Modules/RenderQueue/QueueSheetView.swift")
        let toggle = try section(sheet, from: "private func toggleHidden",
                                to: "private func preparePreviewForRemoval")
        for forbidden in ["viewModel.remove(", "FileManager", "PHAsset", "PhotosPicker",
                          "outputURL =", ".status = .", "import Photos"] {
            #expect(!toggle.contains(forbidden), "Hide is presentation only: \(forbidden)")
        }
        #expect(toggle.contains("viewModel.historyVisibility.show(job.id)"),
                "Hidden-mode Unhide reuses the same continuation path")
        #expect(toggle.contains("viewModel.historyVisibility.hide(job.id)"))
        #expect(!toggle.contains("persist"), "The store keeps owning persistence")
    }
}
