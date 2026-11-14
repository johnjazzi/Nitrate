import CoreGraphics
import Foundation
import Testing

/// The compact stock picker's layout contract: three quiet rows whose content
/// fits a short detent without scrolling, a gauge that gives ground before the
/// push/pull pill does, and a Dynamic Type fallback that is taller on purpose
/// because it is read in a scroll view instead of being clipped.
///
/// The rendering (chip emphasis, the shared controls themselves) is exercised on
/// device; these are the numbers the view's frames are built from.
struct CompactStockPickerTests {
    // MARK: - The gauge and the pill share one row

    @Test func atTheCompactContentWidthTheGaugeTakesItsPreferredShare() {
        let widths = CompactStockPickerLayout.controlWidths(forContentWidth: 320)
        #expect(widths.gauge == CompactStockPickerLayout.preferredGaugeWidth)
        #expect(widths.pushPull == CompactStockPickerLayout.pushPullWidth)
        #expect(widths.total == 284)
        #expect(widths.total <= CompactStockPickerLayout.compactContentWidth)
    }

    /// A narrower detent still fits: the gauge is capped, never overflowing the
    /// content width it was given.
    @Test(arguments: [288.0, 300.0, 320.0, 348.0, 380.0])
    func theRowNeverExceedsTheWidthItIsGiven(width: Double) {
        let content = CGFloat(width)
        let widths = CompactStockPickerLayout.controlWidths(forContentWidth: content)
        #expect(widths.total <= content)
        #expect(widths.gauge >= CompactStockPickerLayout.minimumGaugeWidth)
        #expect(widths.gauge <= CompactStockPickerLayout.preferredGaugeWidth)
    }

    /// The pill keeps its width while the gauge shrinks — the four segments are
    /// the part that can give ground.
    @Test func theGaugeGivesGroundBeforeThePillDoes() {
        let wide = CompactStockPickerLayout.controlWidths(forContentWidth: 320)
        let narrow = CompactStockPickerLayout.controlWidths(forContentWidth: 250)
        #expect(narrow.pushPull == wide.pushPull)
        #expect(narrow.gauge < wide.gauge)
        #expect(narrow.gauge == 166)
    }

    @Test func theGaugeKeepsAFloorThatStillReadsAFourSegmentLadder() {
        let widths = CompactStockPickerLayout.controlWidths(forContentWidth: 160)
        #expect(widths.gauge == CompactStockPickerLayout.minimumGaugeWidth)
        #expect(widths.gauge / 4 >= 36)
    }

    /// A caller that has not measured its width yet must not collapse the row.
    @Test func anUnmeasuredWidthFallsBackToTheCompactWidth() {
        let widths = CompactStockPickerLayout.controlWidths(forContentWidth: .nan)
        #expect(widths == CompactStockPickerLayout.controlWidths(
            forContentWidth: CompactStockPickerLayout.compactContentWidth))
    }

    // MARK: - Heights

    @Test func theSideBySideContentFitsACompactDetentWithoutScrolling() {
        #expect(CompactStockPickerLayout.sideBySideContentHeight
                    <= CompactStockPickerLayout.maximumContentHeight)
        #expect(CompactStockPickerLayout.sideBySideContentHeight
                    == CompactStockPickerLayout.stockRowHeight
                        + CompactStockPickerLayout.rowSpacing
                        + CompactStockPickerLayout.nameRowHeight
                        + CompactStockPickerLayout.rowSpacing
                        + CompactStockPickerLayout.controlHeight)
    }

    /// The stack is not a quiet second layout: it is taller than the compact
    /// detent, which is exactly why it is wrapped in a scroll view.
    @Test func theAccessibilityStackIsTallerAndScrolls() {
        let stacked = CompactStockPickerLayout.stackedContentHeight
        #expect(stacked > CompactStockPickerLayout.sideBySideContentHeight)
        #expect(stacked == CompactStockPickerLayout.sideBySideContentHeight
                    + CompactStockPickerLayout.controlSpacing
                    + CompactStockPickerLayout.controlHeight)
        #expect(stacked > CompactStockPickerLayout.maximumContentHeight)
    }

    // MARK: - Expanded state

    /// The caller's reserved control stack and the row gap come out first: the
    /// preview is what gets the remainder, never a share of the sheet. With
    /// plenty of room that remainder *is* the preview's height.
    @Test func thePreviewTakesTheRemainderAfterTheReservedControls() {
        let reserved = CompactStockPickerLayout.sideBySideContentHeight
        let split = CompactStockPickerLayout.expandedPreview(forAvailableHeight: 900,
                                                             reservedContentHeight: reserved)
        #expect(split.fits)
        #expect(split.height == 900 - reserved - CompactStockPickerLayout.rowSpacing,
                "The controls are reserved first; the preview gets everything else.")
        #expect(split.height > reserved,
                "A tall detent grows the preview, not the controls.")
    }

    /// Exactly at the floor the preview still fits: 448pt plus the reserved
    /// stack plus the gap is the threshold, and it is inclusive.
    @Test func atTheThresholdThePreviewRemainsAFullPlate() {
        let reserved = CompactStockPickerLayout.sideBySideContentHeight
        let threshold = reserved + CompactStockPickerLayout.rowSpacing
            + CompactStockPickerLayout.preferredPreviewHeight
        let split = CompactStockPickerLayout.expandedPreview(forAvailableHeight: threshold,
                                                             reservedContentHeight: reserved)
        #expect(split.fits, "At the threshold the plate is not cropped.")
        #expect(split.height == CompactStockPickerLayout.preferredPreviewHeight)
        #expect(CompactStockPickerLayout.preferredPreviewHeight == 448,
                "448pt is the plate row plus its dots and disclaimer.")
    }

    /// Below the threshold the preview is held at its 448pt floor and the
    /// picker scrolls: the bounded height is what the scroll view gets, so
    /// neither a control nor the plate is cropped.
    @Test func belowTheThresholdThePreviewIsHeldAtItsFloorAndScrolls() {
        let reserved = CompactStockPickerLayout.sideBySideContentHeight
        let split = CompactStockPickerLayout.expandedPreview(forAvailableHeight: reserved + 300,
                                                             reservedContentHeight: reserved)
        #expect(!split.fits, "Too little room for a usable plate means the picker scrolls.")
        #expect(split.height == CompactStockPickerLayout.preferredPreviewHeight,
                "The floor bounds the scroll height at 448pt instead of shrinking the plate.")
    }

    /// More height always grows the preview: the controls keep their measured
    /// stack, so the extra room never moves the gauge or the pill.
    @Test func moreHeightGrowsThePreviewAndNotTheControls() {
        let reserved = CompactStockPickerLayout.sideBySideContentHeight
        let short = CompactStockPickerLayout.expandedPreview(forAvailableHeight: 800,
                                                             reservedContentHeight: reserved)
        let tall = CompactStockPickerLayout.expandedPreview(forAvailableHeight: 940,
                                                            reservedContentHeight: reserved)
        #expect(short.fits && tall.fits)
        #expect(tall.height - short.height == 140,
                "The whole extra height goes to the preview.")
    }

    /// A caller that has scaled its chip row with Dynamic Type passes that
    /// taller reservation in, and the preview gives up exactly that much.
    @Test func aTallerReservedStackTakesItsRoomFromThePreview() {
        let compact = CompactStockPickerLayout.expandedPreview(forAvailableHeight: 900,
                                                               reservedContentHeight: 224)
        let scaled = CompactStockPickerLayout.expandedPreview(forAvailableHeight: 900,
                                                              reservedContentHeight: 300)
        #expect(compact.height - scaled.height == 76,
                "The reservation is the caller's, measured at the size the stack is laid out at.")
    }

    // MARK: - The chip strip

    /// The shipped three video stocks are all visible at the compact width, so
    /// picking a stock never needs a swipe first.
    @Test func theShippedCatalogueFitsTheStrip() {
        let width = CompactStockPickerLayout.stockRowWidth(stockCount: 3)
        #expect(width == 298)
        #expect(width <= CompactStockPickerLayout.compactContentWidth)
    }

    @Test func aGrowingCatalogueScrollsRatherThanShrinkingItsChips() {
        #expect(CompactStockPickerLayout.stockRowWidth(stockCount: 4)
                    > CompactStockPickerLayout.compactContentWidth)
        #expect(CompactStockPickerLayout.stockRowWidth(stockCount: 0) == 0)
    }
}
