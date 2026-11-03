import CoreGraphics
import CoreText
import Foundation
import Testing

/// The stock sheet's contract: three stacked rows that fill the sheet — the
/// example preview on three quarters of the height, then the stock carousel and
/// the gauge + push/pull row sharing the last quarter. The rows are
/// arithmetic shares of the height the sheet has, not intrinsic sizes, so the
/// controls are never pushed below the fold or into a scroll.
struct StockSheetLayoutTests {
    // Heights are the content area of the stock sheet on a phone (its 16pt
    // padding and the fixed Render row already taken out): a short sheet through
    // to a tall one.
    private static let phoneHeights: [Double] = [420, 470, 520, 560, 620]
    // Widths are that same content area: iPhone SE (288), mini (343), 15/16
    // (361) and Max (398).
    private static let phoneWidths: [Double] = [288, 343, 361, 398]

    // MARK: - The three rows

    @Test(arguments: phoneHeights)
    func theThreeRowsFillTheSheetWithoutOverflowing(height: Double) {
        let rows = StockSheetLayout.rows(forAvailableHeight: CGFloat(height))
        #expect(abs(rows.total - CGFloat(height)) < 0.001,
                "The rows must neither overflow nor leave a gap at \(height)pt.")
    }

    @Test(arguments: phoneHeights)
    func thePreviewTakesThreeQuartersAndTheControlsShareTheRest(height: Double) {
        let rows = StockSheetLayout.rows(forAvailableHeight: CGFloat(height))
        let available = CGFloat(height) - StockSheetLayout.rowSpacing * 2
        // The control rows carry minimum heights, so on a short sheet they keep
        // their floor and the preview takes the remainder: three quarters is the
        // target, never less than the two thirds a floor can force.
        #expect(abs(rows.preview / available - StockSheetLayout.previewFraction) < 0.06,
                "The preview is the requested three quarters of the sheet at \(height)pt.")
        #expect(rows.preview / available > 0.6,
                "The preview stays the dominant row at \(height)pt.")
        #expect(abs(rows.stocks / available - StockSheetLayout.stocksFraction) < 0.06,
                "The stock carousel is the requested eighth at \(height)pt.")
        #expect(abs(rows.controls / available - StockSheetLayout.controlsFraction) < 0.03,
                "The gauge and push/pull row is the requested eighth at \(height)pt.")
    }

    @Test(arguments: phoneHeights)
    func eachControlRowClearsItsOwnContent(height: Double) {
        let rows = StockSheetLayout.rows(forAvailableHeight: CGFloat(height))
        #expect(rows.stocks >= StockSheetLayout.minimumStocksHeight,
                "A quarter of \(height)pt must still hold a carousel card and its page dot.")
        #expect(rows.controls >= StockSheetLayout.minimumControlsHeight,
                "A quarter of \(height)pt must still hold the gauge caption and its control.")
        #expect(rows.preview > rows.stocks, "The preview stays the tallest row at \(height)pt.")
    }

    /// The owner's rule: if the sheet is short, the preview gives up height
    /// first. The control rows keep their floors, so nothing clips or scrolls.
    @Test(arguments: [180.0, 200.0, 240.0])
    func aShortSheetShrinksThePreviewFirst(height: Double) {
        let rows = StockSheetLayout.rows(forAvailableHeight: CGFloat(height))
        #expect(abs(rows.total - CGFloat(height)) < 0.001)
        #expect(rows.stocks >= StockSheetLayout.minimumStocksHeight,
                "The carousel keeps its floor at \(height)pt.")
        #expect(rows.controls >= StockSheetLayout.minimumControlsHeight,
                "The gauge row keeps its floor at \(height)pt.")
        let available = CGFloat(height) - StockSheetLayout.rowSpacing * 2
        #expect(rows.preview < available * StockSheetLayout.previewFraction,
                "The preview, not a control, absorbs the shortfall at \(height)pt.")
    }

    @Test func anImpossiblyShortSheetStillSumsToItsHeight() {
        let rows = StockSheetLayout.rows(forAvailableHeight: 120)
        #expect(abs(rows.total - 120) < 0.001, "Even squeezed, the rows must not overflow.")
        #expect(rows.preview == 0, "With no room left the preview is what disappears.")
    }

    // MARK: - The shared bottom row

    @Test(arguments: phoneWidths)
    func theGaugeAndPillFillTheBottomRowWithoutOverflowing(width: Double) {
        let widths = StockSheetLayout.controlWidths(forAvailableWidth: CGFloat(width))
        #expect(abs(widths.total - CGFloat(width)) < 0.001,
                "The bottom row must neither overflow nor leave a gap at \(width)pt.")
    }

    @Test(arguments: phoneWidths)
    func thePillTakesAboutAFifthOfTheBottomRow(width: Double) {
        let widths = StockSheetLayout.controlWidths(forAvailableWidth: CGFloat(width))
        #expect(widths.pushPull >= StockSheetLayout.minimumPushPullWidth)
        #expect(abs(widths.pushPull / CGFloat(width) - StockSheetLayout.pushPullFraction) < 0.02,
                "Push/pull is the requested fifth of the row at \(width)pt.")
        // At every phone width the fifth itself decides the width; the floor
        // exists only for rows too narrow for 20% to be usable.
        #expect(widths.pushPull == CGFloat(width) * StockSheetLayout.pushPullFraction,
                "The fifth, not the minimum, must set the width at \(width)pt.")
    }

    @Test(arguments: phoneWidths)
    func theGaugeIsTheLargerShareAndKeepsFourLegibleSegments(width: Double) {
        let widths = StockSheetLayout.controlWidths(forAvailableWidth: CGFloat(width))
        #expect(widths.gauge > widths.pushPull * 3,
                "The gauge takes the larger share of the bottom row at \(width)pt.")
        let segments = widths.gauge / CGFloat(PrintGauge.allCases.count)
        #expect(segments >= 28, "A gauge segment needs ~28pt for a two-digit label at \(width)pt.")
    }

    /// The pill shows one word, so it must not need to shrink to fit its fifth.
    /// Measured with the app's own face at the caption2 size; an unregistered
    /// face in the test process falls back to a wider system font, which only
    /// makes this check stricter.
    @Test func theWidestPillWordFitsTheNarrowestPill() {
        let narrowest = StockSheetLayout.controlWidths(forAvailableWidth: 288).pushPull
        let font = CTFontCreateWithName(NitrateTypography.postScriptName as CFString, 11, nil)
        for word in ["PUSH", "PULL", "0"] {
            let width = Self.width(of: word, font: font)
            #expect(width + 8 <= narrowest,
                    "\(word) renders \(width)pt wide; the pill is \(narrowest)pt.")
        }
    }

    private static func width(of text: String, font: CTFont) -> CGFloat {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return .infinity }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    // MARK: - The carousel card fits its quarter

    @Test(arguments: [110.0, 140.0, 180.0])
    func theCarouselCardFitsItsRowAndKeepsItsShape(height: Double) {
        let cardHeight = StockCarouselMetrics.cardHeight(forAvailableHeight: CGFloat(height))
        #expect(cardHeight + StockCarouselMetrics.chromeHeight <= CGFloat(height),
                "The card plus its page dot must fit the \(height)pt row.")
        let cardWidth = StockCarouselMetrics.cardWidth(forCardHeight: cardHeight)
        #expect(abs(cardWidth / cardHeight - StockCarouselMetrics.cardAspect) < 0.001)
        #expect(cardWidth >= 60, "A card narrower than 60pt cannot show its stock name.")
    }

    @Test func aTallerRowDoesNotBlowUpTheCard() {
        #expect(StockCarouselMetrics.cardHeight(forAvailableHeight: 400) == StockCarouselMetrics.maximumCardHeight)
    }

    // MARK: - The view actually stacks them

    @Test func theSheetStacksPreviewThenStockThenControls() throws {
        let body = try sheetBody()
        #expect(!body.contains("ScrollView(.vertical)"),
                "A vertical ScrollView is what hid the push/pull picker below the fold.")
        let preview = try #require(body.range(of: "frame(height: rows.preview)"))
        let stocks = try #require(body.range(of: "stockCarousel.frame(height: rows.stocks)"))
        let controls = try #require(body.range(of: "controlRow.frame(height: rows.controls)"))
        #expect(preview.lowerBound < stocks.lowerBound && stocks.lowerBound < controls.lowerBound,
                "The rows must be preview, then the stock carousel, then the gauge and push/pull.")
        #expect(body.contains("StockSheetLayout.rows(forAvailableHeight: proxy.size.height)"),
                "The heights must come from the sheet's real height, not from intrinsic sizes.")
    }

    @Test func theStockIsACarouselAgainRatherThanADropdown() throws {
        let body = try sheetBody()
        #expect(!body.contains("stockCell"), "The stock dropdown cell must be gone.")
        #expect(!body.contains("chevron.down"), "A dropdown chevron means the old selector is back.")
        #expect(!body.contains("accessibilityIdentifier(\"stock.selection\")"),
                "The dropdown's identifier goes with the dropdown.")
        #expect(body.contains("StockCarousel(stocks: stocks, selectedStockId: selectedStockIdBinding)"),
                "The old stock carousel is what presents the catalogue.")
        #expect(body.contains("accessibilityIdentifier(\"stock.carousel\")"),
                "UI tests need a stable identifier for the carousel.")
        #expect(body.contains("accessibilityIdentifier(\"stock.gauge\")"),
                "The gauge identifier stays as it was.")
    }

    @Test func theGaugeAndThePillShareTheBottomRow() throws {
        let row = try controlRowBody()
        #expect(row.contains("gaugeCell.frame(width: widths.gauge)"),
                "The gauge is the left cell of the bottom row.")
        #expect(row.contains("pushPullPill.frame(width: widths.pushPull)"),
                "The pill keeps its fixed fifth beside the gauge.")
        #expect(row.contains("StockSheetLayout.controlWidths(forAvailableWidth:"),
                "The bottom row splits the width arithmetically.")
        #expect(!row.contains("stockCell"), "Stock is in its own row now, not in the bottom one.")
    }

    @Test func pushPullKeepsItsLadderAndItsAutoEntry() throws {
        let body = try sheetBody()
        #expect(body.contains("accessibilityIdentifier(\"stock.pushPull\")"),
                "UI tests need a stable identifier for the push/pull control.")
        #expect(!body.contains("Toggle(isOn: $pushPullAutomatic)"),
                "The auto/manual choice lives in the menu, not in a second control.")
        #expect(body.contains("Auto from the meter"),
                "Auto must remain reachable from the menu.")
        #expect(body.contains("ForEach(PushPullStops.allCases)"),
                "The -3..+2 ladder stays: every rung is still offered.")
        #expect(!body.contains("Text(\"Push / Pull\")"),
                "The removed Push / Pull headline must not come back.")
        #expect(!body.contains("pushPullBadge"),
                "The removed badge must not come back.")
    }

    @Test func theClosedPillIsOneWordInItsFixedSlot() throws {
        let body = try sheetBody()
        #expect(body.contains("resolvedPushPull.stops.effectWord"),
                "The pill must read the effective stops, so auto tracks the meter.")
        #expect(body.contains("pushPullPill.frame(width: widths.pushPull)"),
                "The pill keeps its fixed fifth of the row instead of sizing to the word.")
    }

    // MARK: - Source helpers

    private func sheetBody() throws -> String {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        return String(source[sheet.lowerBound...])
    }

    private func controlRowBody() throws -> String {
        let body = try sheetBody()
        let start = try #require(body.range(of: "private var controlRow"))
        let end = try #require(body.range(of: "private var sheetFooter"))
        return String(body[start.lowerBound..<end.lowerBound])
    }
}
