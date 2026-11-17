import Foundation
import Testing

/// Source contracts for the stock strip printed on the shared contact frame.
///
/// `ContactPreviewFrame` is a SwiftUI view the macOS test target does not
/// compile. These tests pin the stock label's rotation on the one shared
/// surface used by Develop review, Develop results and History. They do not
/// prove visual readability: that is owner feedback on a device build.
@Suite("Contact stock strip printing contracts")
struct ContactStockPrintingTests {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func section(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try #require(text.range(of: startMarker))
        let end = try #require(text.range(of: endMarker, range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func stockStripReadsTopToBottomOnTheSharedFrame() throws {
        let frame = try source("App/Modules/RenderQueue/ContactPreviewFrame.swift")
        let leftBand = try section(frame, from: "HStack(spacing: 0) {", to: "content()")

        #expect(leftBand.contains("frameLabel(stockAndGauge, degrees: 90)"),
                "The stock strip must read top-to-bottom, not bottom-to-top")
        #expect(!frame.contains("frameLabel(stockAndGauge, degrees: -90)"),
                "The old bottom-to-top stock rotation is the upside-down regression")
        #expect(occurrences(of: "frameLabel(stockAndGauge", in: frame) == 1,
                "Stock printing stays on the one shared frame band")
    }

    @Test func stockRotationLeavesTheRestOfTheContactFrameAlone() throws {
        let frame = try source("App/Modules/RenderQueue/ContactPreviewFrame.swift")

        // Right-hand metadata keeps its upright-in-landscape rotation.
        #expect(frame.contains("frameLabel(exposure, degrees: 90)"))
        #expect(frame.contains("frameLabel(frameRate, degrees: 90, alignment: .trailing)"))
        // The frame's media, bands and print treatment are unchanged.
        #expect(frame.contains("private let borderWidth: CGFloat = 24"))
        #expect(frame.contains("private let topInset: CGFloat = 10"))
        #expect(frame.contains("private let bottomInset: CGFloat = 24"))
        #expect(frame.contains("private let printColor = Color.white.opacity(0.85)"))
        #expect(frame.contains("QueueFrameStripBorder()"))
        #expect(frame.contains("formatter.dateFormat = \"yyyy-MM-dd HH:mm\""))
        // Only the label typography rotates; the image never does.
        #expect(!frame.contains("content().rotationEffect"))
        #expect(!frame.contains("UIDevice"))
        #expect(!frame.contains("interfaceOrientation"))
    }

    @Test func noSecondStockPrintingPathExistsOnTheContactSheet() throws {
        let history = try source("App/Modules/RenderQueue/HistoryInlinePreview.swift")
        let preview = try source("App/Modules/VideoImport/DevelopPreview.swift")
        let results = try source("App/Modules/VideoImport/DevelopResultsPager.swift")
        for surface in [history, preview, results] {
            #expect(surface.contains("ContactPreviewFrame("),
                    "Every stock strip is printed by the shared contact frame")
            #expect(!surface.contains("frameLabel(stockAndGauge"),
                    "No surface may rotate the stock label on its own")
        }

        // The grid cells print their metadata outside the poster and own no
        // rotated stock band; QueueContactSheet is pure layout.
        let cards = try source("App/Modules/RenderQueue/QueueReceiptViews.swift")
        let layout = try source("App/Modules/RenderQueue/QueueContactSheet.swift")
        for file in [cards, layout] {
            #expect(!file.contains("frameLabel("),
                    "The grid must not grow a duplicate stock side label")
            #expect(!file.contains("struct ContactPreviewFrame"),
                    "The grid reuses the shared frame instead of a preview twin")
        }
        #expect(!layout.contains("rotationEffect"), "The grid layout never rotates print")
    }
}
