import CoreGraphics
import CoreText
import Foundation
import Testing

/// The stock sheet used to stack the preview, carousel, gauge and push/pull in a
/// vertical scroll, which put the push/pull picker below the fold on a phone.
/// These pin the one-row replacement: the widths add up, the push/pull dropdown
/// keeps its fifth, and the gauge stays wide enough for four segments.
struct StockControlRowLayoutTests {
    // Widths checked below are the content area of a sheet with 16pt padding:
    // iPhone SE (288), mini (343), 15/16 (361) and Max (398).

    @Test(arguments: [288.0, 343.0, 361.0, 398.0])
    func theThreeCellsFillTheRowWithoutOverflowing(width: Double) {
        let widths = StockControlRowLayout.widths(forAvailableWidth: CGFloat(width))
        #expect(abs(widths.total - CGFloat(width)) < 0.001,
                "The row must neither overflow nor leave a gap at \(width)pt.")
    }

    @Test(arguments: [288.0, 343.0, 361.0, 398.0])
    func pushPullTakesAboutAFifthOfTheRow(width: Double) {
        let widths = StockControlRowLayout.widths(forAvailableWidth: CGFloat(width))
        #expect(widths.pushPull >= StockControlRowLayout.minimumPushPullWidth)
        #expect(abs(widths.pushPull / CGFloat(width) - StockControlRowLayout.pushPullFraction) < 0.02,
                "Push/pull is the requested fifth of the row at \(width)pt.")
        // At every phone width the fifth itself decides the width; the floor
        // exists only for rows too narrow for 20% to be usable.
        #expect(widths.pushPull == CGFloat(width) * StockControlRowLayout.pushPullFraction,
                "The fifth, not the minimum, must set the width at \(width)pt.")
    }

    @Test(arguments: [288.0, 343.0, 361.0, 398.0])
    func theGaugeKeepsFourLegibleSegments(width: Double) {
        let widths = StockControlRowLayout.widths(forAvailableWidth: CGFloat(width))
        let segments = widths.gauge / CGFloat(PrintGauge.allCases.count)
        #expect(segments >= 28, "A gauge segment needs ~28pt for a two-digit label at \(width)pt.")
    }

    @Test(arguments: [288.0, 343.0, 361.0, 398.0])
    func theStockKeepsRoomForItsSwatchAndName(width: Double) {
        let widths = StockControlRowLayout.widths(forAvailableWidth: CGFloat(width))
        #expect(widths.stock >= StockControlRowLayout.minimumStockWidth)
        #expect(widths.stock > widths.gauge * 0.5)
    }

    /// The pill shows one word, so it must not need to shrink to fit its fifth.
    /// Measured with the app's own face at the caption2 size; an unregistered
    /// face in the test process falls back to a wider system font, which only
    /// makes this check stricter.
    @Test func theWidestPillWordFitsTheNarrowestPill() {
        let narrowest = StockControlRowLayout.widths(forAvailableWidth: 288).pushPull
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

    @Test func theStockSheetHasNoVerticalScrollAroundItsControls() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        let body = String(source[sheet.lowerBound...])
        #expect(!body.contains("ScrollView(.vertical)"),
                "A vertical ScrollView is what hid the push/pull picker below the fold.")
        #expect(body.contains("controlRow"),
                "Stock, gauge and push/pull must sit in the one shared control row.")
    }

    @Test func pushPullIsADropdownRatherThanAToggle() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        let body = String(source[sheet.lowerBound...])
        #expect(body.contains("accessibilityIdentifier(\"stock.pushPull\")"),
                "UI tests need a stable identifier for the push/pull control.")
        #expect(!body.contains("Toggle(isOn: $pushPullAutomatic)"),
                "The auto/manual choice lives in the dropdown now, not in a second control.")
        #expect(body.contains("Auto from the meter"),
                "Auto must remain reachable from the dropdown.")
    }

    @Test func theClosedControlIsOneWordInAFixedPill() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        let body = String(source[sheet.lowerBound...])
        #expect(body.contains("resolvedPushPull.stops.effectWord"),
                "The pill must read the effective stops, so auto tracks the meter.")
        #expect(body.contains("pushPullPill.frame(width: widths.pushPull)"),
                "The pill keeps its fixed fifth of the row instead of sizing to the word.")
    }
}
