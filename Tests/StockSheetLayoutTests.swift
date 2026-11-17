import CoreGraphics
import CoreText
import Foundation
import Testing

/// The stock sheet's arithmetic: the rows that fill a sheet and the split of its
/// bottom row, still exposed as pure geometry (`StockSheetLayout`,
/// `StockCarouselMetrics`) even though the live sheet now seats one
/// `CompactStockPicker` at both detents. The view contracts themselves live in
/// the tests below, read from the picker the sheet actually draws.
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
        // The carousel has a real minimum so its cards keep their shape, so the
        // preview takes the remainder: three quarters is the target, 60% the
        // floor a tall carousel can force on a short sheet.
        #expect(rows.preview / available <= StockSheetLayout.previewFraction + 0.01,
                "The preview never exceeds three quarters at \(height)pt.")
        #expect(rows.preview > rows.stocks,
                "The preview stays the dominant row at \(height)pt.")
        #expect(rows.stocks >= StockSheetLayout.minimumStocksHeight,
                "The carousel keeps its card height at \(height)pt.")
        #expect(rows.controls >= StockSheetLayout.minimumControlsHeight,
                "The gauge and push/pull row keeps its floor at \(height)pt.")
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
    /// first. At these heights the two control floors together exceed the sheet,
    /// so all three rows scale down proportionally instead of the rows
    /// overflowing: there is nothing left for the preview to give.
    @Test(arguments: [180.0, 200.0, 240.0])
    func aShortSheetShrinksThePreviewFirst(height: Double) {
        let rows = StockSheetLayout.rows(forAvailableHeight: CGFloat(height))
        #expect(abs(rows.total - CGFloat(height)) < 0.001)
        let available = CGFloat(height) - StockSheetLayout.rowSpacing * 2
        #expect(rows.preview < available * StockSheetLayout.previewFraction,
                "The preview, not a control, absorbs the shortfall at \(height)pt.")
        #expect(rows.preview + rows.stocks + rows.controls <= available + 0.001,
                "The rows never exceed the sheet at \(height)pt.")
    }

    @Test func anImpossiblyShortSheetStillSumsToItsHeight() {
        let rows = StockSheetLayout.rows(forAvailableHeight: 120)
        #expect(abs(rows.total - 120) < 0.001, "Even squeezed, the rows must not overflow.")
        #expect(rows.preview == 0, "With no room left the preview is what disappears.")
    }

    // MARK: - The shared bottom row

    @Test(arguments: phoneWidths)
    func theGaugeAndPillsFillTheBottomRowWithoutOverflowing(width: Double) {
        let widths = StockSheetLayout.controlWidths(forAvailableWidth: CGFloat(width))
        #expect(abs(widths.total - CGFloat(width)) < 0.001,
                "The bottom row must neither overflow nor leave a gap at \(width)pt.")
        // Three cells and two gaps now: the same arithmetic must still add up,
        // or a cell gets clipped off the trailing edge of the sheet.
        #expect(widths.flash >= StockSheetLayout.minimumFlashWidth)
        #expect(widths.gauge + widths.pushPull + widths.flash
                + StockSheetLayout.controlSpacing * 2 == widths.total)
    }

    /// A camera with no lamp hides the cell, and the row then splits exactly as
    /// it did before the control existed: the third cell must not leave a gap.
    @Test(arguments: phoneWidths)
    func withoutALampTheRowSplitsAsItDidBeforeTheControlExisted(width: Double) {
        let widths = StockSheetLayout.controlWidths(forAvailableWidth: CGFloat(width),
                                                    includesFlash: false)
        #expect(widths.flash == 0)
        #expect(abs(widths.total - CGFloat(width)) < 0.001,
                "A hidden cell must not leave a gap at \(width)pt.")
        // The pre-lamp split: one gap, the pill a fixed fifth, the gauge the rest.
        #expect(widths.pushPull == CGFloat(width) * StockSheetLayout.pushPullFraction)
        #expect(widths.gauge == CGFloat(width) - widths.pushPull - StockSheetLayout.controlSpacing)
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
        #expect(widths.gauge > widths.pushPull,
                "The gauge takes the larger share of the bottom row at \(width)pt.")
        #expect(widths.gauge > widths.flash,
                "Both pills are fifths; the gauge keeps the rest at \(width)pt.")
        let segments = widths.gauge / CGFloat(PrintGauge.allCases.count)
        #expect(segments >= 28, "A gauge segment needs ~28pt for a two-digit label at \(width)pt.")
    }

    /// The third cell's closed reading is `OFF` or a percentage. `100%` is the
    /// widest thing it ever has to show, so it decides whether the fifth is
    /// honest on the narrowest phone.
    @Test func theWidestFlashReadingFitsTheNarrowestCell() {
        let narrowest = StockSheetLayout.controlWidths(forAvailableWidth: 288).flash
        let font = CTFontCreateWithName(NitrateTypography.postScriptName as CFString, 11, nil)
        for reading in ["OFF", "5%", "40%", "100%"] {
            let width = Self.width(of: reading, font: font)
            #expect(width + 8 <= narrowest,
                    "\(reading) renders \(width)pt wide; the cell is \(narrowest)pt.")
        }
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

    // MARK: - The view: one picker at both heights

    /// The live sheet is not three arithmetic rows any more: both entries seat
    /// the same `CompactStockPicker`, and the detent only decides whether that
    /// picker reveals the sample preview above its one control stack.
    @Test func theSheetPresentsOnePickerAtBothHeights() throws {
        let body = try sheetBody()
        #expect(body.components(separatedBy: "CompactStockPicker(stocks: stocks").count == 2,
                "The picker is seated once, not as a compact layout and a second full one.")
        #expect(body.contains("expanded: isExpanded"),
                "The large detent reveals the preview inside the same picker.")
        #expect(body.contains("if isExpanded { sheetFooter }"),
                "Only the expanded state has room for the note under the controls.")
        #expect(!body.contains("classicContents"), "The removed full-only stack must not come back.")
        #expect(!body.contains("stockCarousel"), "The removed carousel row must not come back.")
        #expect(!body.contains("controlRow"), "The removed sheet-level control row must not come back.")
        #expect(body.contains(".presentationDetents([.height(360), .large], selection: detentSelection)"),
                "Both heights stay reachable from either entry, and the entry picks the first one.")
        #expect(!body.contains("presentationDetents(entry =="),
                "A single-detent sheet is what made one entry the only reachable height.")
    }

    /// The first presentation is the entry's own height; a drag afterwards is
    /// the only thing that writes the override, and it writes nothing else.
    @Test func theEntrySetsTheFirstDetentAndOnlyADragOverridesIt() throws {
        let body = try sheetBody()
        #expect(body.contains("private var resolvedEntry: CameraStockEntry { presentationOverride ?? entry }"),
                "Until a drag, the resolved entry is exactly what the bar asked for.")
        #expect(body.contains("private var isExpanded: Bool { resolvedEntry == .full }"))
        #expect(body.contains("get: { resolvedEntry == .full ? .large : .height(360) }"),
                "Both detents map back onto the two entries.")
        let setter = try detentSetterBody()
        #expect(setter.contains("presentationOverride = target"))
        #expect(setter.contains("guard target != resolvedEntry else { return }"),
                "Settling onto the current detent must not write state.")
        #expect(body.components(separatedBy: "presentationOverride = ").count == 2,
                "Only the detent setter writes the override — never onAppear, never a preference.")
    }

    /// Appearing keeps the remembered stock state and never resizes the sheet;
    /// dismissing commits the gauge and push/pull back to the stock.
    @Test func appearingLeavesTheHeightAloneAndTheSelectionSurvives() throws {
        let body = try sheetBody()
        let appear = try section(from: ".onAppear {", to: ".onDisappear {", in: body)
        #expect(!appear.contains("presentationOverride"),
                "The sheet must not settle onto a height after appearing.")
        #expect(!appear.contains("presentationDetents"))
        #expect(appear.contains("stocks = library.videoStocks()"),
                "The picker's chips are fed from the catalogue on first appearance.")
        #expect(appear.contains("library.lastGauge(for:"), "The stock's remembered gauge is restored.")
        #expect(appear.contains("restorePushPull(for: localSelection)"),
                "The remembered push/pull is restored with the same selection.")
        #expect(appear.contains("currentISO = localSelection?.defaultISO"))
        let disappear = try section(from: ".onDisappear {", to: ".onChange(of: localSelection)", in: body)
        #expect(disappear.contains("library.setGauge(gauge, for: stock.stockId)"),
                "Collapsing or dismissing keeps the gauge the operator dialled in.")
        #expect(disappear.contains("library.setPushPull(pushPullPreference, for: stock.stockId)"),
                "Collapsing or dismissing keeps the push/pull rung and Auto.")
    }

    @Test func theCatalogueIsAChipStripInsideThePicker() throws {
        let picker = try pickerSource()
        #expect(!picker.contains("chevron.down"), "A dropdown chevron means the old selector is back.")
        #expect(!picker.contains("accessibilityIdentifier(\"stock.selection\")"),
                "The dropdown's identifier goes with the dropdown.")
        #expect(picker.contains("accessibilityIdentifier(\"stock.compactPicker\")"),
                "UI tests need one stable identifier for both heights of the picker.")
        #expect(picker.contains("ForEach(stocks, id: \\.stockId)"),
                "Every stock is a chip in the strip, at both heights.")
        #expect(picker.contains("accessibilityIdentifier(\"stock.choice.\\(stock.stockId)\")"),
                "Each chip stays individually addressable.")
        #expect(picker.contains("selectedStockId = stock.stockId"),
                "A chip tap writes the one selection and nothing else.")
        #expect(picker.contains("if expanded { expandedContent } else { compactContent }"),
                "One component, two height states — not two controls trees.")
    }

    @Test func theGaugeAndThePillShareTheBottomRow() throws {
        let picker = try pickerSource()
        #expect(picker.contains("GaugeControl(gauge: $gauge, enlarged: true)"),
                "The gauge is the shared enlarged control, not a sheet-local copy.")
        #expect(picker.contains("PushPullControl(resolved: resolvedPushPull,"),
                "The pill is the shared component, fed the exposure the render will apply.")
        #expect(picker.contains(".frame(width: CompactStockPickerLayout.pushPullWidth)"),
                "The pill keeps its fixed slot beside the gauge.")
        #expect(picker.contains("whiteBalance == nil ? CompactStockPickerLayout.preferredGaugeWidth"),
                "Camera keeps the original gauge share when the Lab-only WB control is absent.")
        #expect(picker.contains(": CompactStockPickerLayout.minimumGaugeWidth"),
                "Lab reserves a readable gauge width beside Push/Pull and WB.")
        #expect(picker.contains("var whiteBalance: Binding<DevelopWhiteBalance>? = nil"))
        #expect(picker.contains("spacing: CompactStockPickerLayout.controlSpacing"))
        #expect(!picker.contains("flashPill"),
                "The lamp lives in the top bar now, not in the picker's bottom row.")
        #expect(!picker.contains("includesFlash"),
                "The picker's row is two cells, so it reserves no gap for a lamp key.")
    }

    @Test func theLampKeyLivesInTheTopBarAndTicksOnEveryPress() throws {
        let source = try sharedSurface()
        #expect(source.contains("} flash: {\n            LampControl("),
                "The lamp key is its own top-bar slot, immediately left of the lens selector.")
        #expect(source.contains("accessibilityIdentifier(\"camera.flash\")"),
                "UI tests need a stable identifier for the lamp key.")
        #expect(source.contains(".onTapGesture { toggle() }"),
                "A short press switches the lamp on or off.")
        #expect(source.contains(".onLongPressGesture(minimumDuration: 0.4)"),
                "A long press opens the lamp's controls and closes them again.")
        #expect(source.contains(".sensoryFeedback(.impact(weight: .medium), trigger: hapticTick)"),
                "Every press ticks.")
        #expect(source.contains("slider(\"Flash\""),
                "Video has one level, and it is called flash.")
        #expect(!source.contains("Fire the lamp"),
                "Video keeps its existing zero-is-off level control.")
        let lamp = try String(contentsOf: TestRepository.url(for: "App/Modules/CameraCapture/LampControl.swift"),
                              encoding: .utf8)
        #expect(lamp.contains("settings.photoIntensity = settings.isPhotoLampOn ? 0 : 1"))
        #expect(lamp.contains("if photoMode {\n                toggle()"),
                "Holding Photo's bolt must use the same On/Off action, not open an adjustment panel")
        #expect(!lamp.contains("Picker(\"Photo flash\""), "Native flash does not need a second On/Off control")
        #expect(!lamp.contains("slider(\"Intensity\""), "Native photo flash has no power slider")
        #expect(!lamp.contains("slider(\"Duration\""), "Native photo flash timing is camera-controlled")
        #expect(!lamp.contains("shapingReason"), "The legacy torch shaping limit must not gate native flash")
        for guidance in ["distance", "metres away", "m away", "\\(distance)"] {
            #expect(!source.contains(guidance), "No distance guidance ships in the UI.")
        }
    }

    @Test func pushPullKeepsItsLadderAndItsAutoEntry() throws {
        let pill = try pushPullSource()
        #expect(pill.contains("accessibilityIdentifier(\"stock.pushPull\")"),
                "UI tests need a stable identifier for the push/pull control.")
        #expect(!pill.contains("Toggle(isOn:"),
                "The auto/manual choice lives in the menu, not in a second control.")
        #expect(pill.contains("Auto from the meter"),
                "Auto must remain reachable from the menu, and stay distinct from a manual 0.")
        #expect(pill.contains("ForEach(PushPullStops.allCases)"),
                "The -3..+2 ladder stays: every rung is still offered.")
        #expect(!pill.contains("Text(\"Push / Pull\")"),
                "The removed Push / Pull headline must not come back.")
        #expect(!pill.contains("pushPullBadge"),
                "The removed badge must not come back.")
        // The picker hands the pill the exposure the render will apply, so Auto
        // tracks the meter instead of reading a second, stale copy.
        let picker = try pickerSource()
        #expect(picker.contains("PushPullControl(resolved: resolvedPushPull,"))
        let surface = try pickerSourceAndSheet()
        #expect(surface.contains("pushPullPreference.resolved(meteredOffsetEV: meteredOffsetEV)"),
                "The resolved exposure is the one the render applies, read against the live meter.")
    }

    @Test func theClosedPillIsOneWordInItsFixedSlot() throws {
        let pill = try pushPullSource()
        // The shared component reads the exposure its caller resolved, so auto
        // still tracks the meter.
        #expect(pill.contains("resolved.stops.effectWord"),
                "The pill must read the effective stops, so auto tracks the meter.")
        #expect(pill.contains(".accessibilityIdentifier(\"stock.pushPull\")"),
                "The pill keeps its identifier in the shared component.")
        let picker = try pickerSource()
        #expect(picker.contains("PushPullControl(resolved: resolvedPushPull,"),
                "The picker passes the live resolved exposure, never a stores-only value.")
        #expect(picker.contains(".frame(width: CompactStockPickerLayout.pushPullWidth)"),
                "The pill keeps its fixed slot instead of sizing to the word.")
    }

    // MARK: - Source helpers

    /// The picker is the one surface both heights draw, so its controls and
    /// identifiers are read from its own file.
    private func pickerSource() throws -> String {
        try String(contentsOf: TestRepository.url(for: "App/Modules/FilmStockLibrary/CompactStockPicker.swift"),
                   encoding: .utf8)
    }

    /// The shared pill owns the ladder, the Auto rung and its identifier.
    private func pushPullSource() throws -> String {
        try String(contentsOf: TestRepository.url(for: "App/Modules/FilmStockLibrary/PushPullControl.swift"),
                   encoding: .utf8)
    }

    /// The sheet plus the picker: the sheet resolves the exposure, the picker
    /// draws it.
    private func pickerSourceAndSheet() throws -> String {
        try sheetBody() + "\n" + (try pickerSource())
    }

    /// The gauge and push/pull surfaces are shared components now, so their
    /// identifiers, menu and labels live in their own files. The contract is
    /// about the surface, not about which file hosts it: read all three.
    private func sharedSurface() throws -> String {
        let paths = ["App/ContentView.swift",
                     "App/Modules/FilmStockLibrary/GaugeControl.swift",
                     "App/Modules/FilmStockLibrary/PushPullControl.swift",
                     "App/Modules/CameraCapture/LampControl.swift"]
        return try paths.map {
            try String(contentsOf: TestRepository.url(for: $0), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private func sheetBody() throws -> String {
        let source = try sharedSurface()
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        return String(source[sheet.lowerBound...])
    }

    private func detentSetterBody() throws -> String {
        let body = try sheetBody()
        return try section(from: "private var detentSelection", to: "// MARK: - Selection", in: body)
    }

    private func section(from start: String, to end: String, in body: String) throws -> String {
        let lower = try #require(body.range(of: start))
        let upper = try #require(body.range(of: end, range: lower.upperBound..<body.endIndex))
        return String(body[lower.upperBound..<upper.lowerBound])
    }
}
