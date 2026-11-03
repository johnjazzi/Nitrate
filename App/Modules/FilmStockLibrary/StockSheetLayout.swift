import CoreGraphics

/// The stock sheet's vertical stack and the split of its bottom row.
///
/// The sheet is three stacked rows that together fill the height it is given:
/// the example preview on top, the stock carousel under it, then the print
/// gauge and the push/pull pill sharing the bottom row. The rows are arithmetic
/// shares of that height — three quarters, then an eighth, then an eighth — not whatever
/// the controls negotiate from their intrinsic sizes. Stacked by content, the
/// preview ate the space the controls needed and the push/pull picker fell below
/// the fold on a phone, which read as the feature being missing.
///
/// Kept free of SwiftUI so the split can be checked at every phone height
/// without rendering.
enum StockSheetLayout {
    /// Gap between the three rows.
    static let rowSpacing: CGFloat = 12
    /// Share of the stack the example preview takes.
    static let previewFraction: CGFloat = 0.75
    /// Share of the stack the stock carousel takes.
    static let stocksFraction: CGFloat = 0.125
    /// Share of the stack the gauge + push/pull row takes.
    static let controlsFraction: CGFloat = 0.125

    /// Smallest carousel that still shows a card with its page dot. A quarter of
    /// a compact sheet clears this; the floor only decides when the sheet is too
    /// short for four quarters of control chrome.
    static let minimumStocksHeight: CGFloat = 64
    /// Gauge caption plus its 34pt segmented control.
    static let minimumControlsHeight: CGFloat = 50

    struct Rows: Equatable {
        var preview: CGFloat
        var stocks: CGFloat
        var controls: CGFloat

        /// What the three rows plus their two gaps occupy.
        var total: CGFloat { preview + stocks + controls + StockSheetLayout.rowSpacing * 2 }
    }

    /// Split `height` — the sheet's real content height — into the three rows.
    /// The two control rows keep their fractions unless that would squeeze them
    /// under their minimum, and the preview absorbs the difference: it is the
    /// row that shrinks first, never the controls that scroll away or clip.
    static func rows(forAvailableHeight height: CGFloat) -> Rows {
        let available = max(height - rowSpacing * 2, 1)
        let stocks = max(available * stocksFraction, minimumStocksHeight)
        let controls = max(available * controlsFraction, minimumControlsHeight)
        let controlRows = stocks + controls
        guard controlRows < available else {
            // Too short for even the two control rows: give the preview nothing
            // and scale the controls down proportionally rather than overflow.
            let scale = available / controlRows
            return Rows(preview: 0, stocks: stocks * scale, controls: controls * scale)
        }
        return Rows(preview: available - controlRows, stocks: stocks, controls: controls)
    }

    // MARK: - Bottom row

    /// Gap between the gauge and the push/pull pill.
    static let controlSpacing: CGFloat = 8
    /// Share of the bottom row the push/pull pill takes.
    static let pushPullFraction: CGFloat = 0.2
    /// Pill floor. A fifth of a 288pt row is 57.6pt, which already clears this,
    /// so the fraction — not the floor — decides every phone width.
    static let minimumPushPullWidth: CGFloat = 56
    /// Gauge floor: four segments at 30pt still read "35".
    static let minimumGaugeWidth: CGFloat = 120

    struct ControlWidths: Equatable {
        var gauge: CGFloat
        var pushPull: CGFloat

        /// What the two cells plus their gap occupy.
        var total: CGFloat { gauge + pushPull + StockSheetLayout.controlSpacing }
    }

    /// Split `width` into the gauge and the pill. The pill is pinned to a fifth
    /// so its one word never widens it; the gauge takes everything else, which
    /// is the larger share its four-segment ladder needs.
    static func controlWidths(forAvailableWidth width: CGFloat) -> ControlWidths {
        let available = max(width, minimumGaugeWidth + minimumPushPullWidth + controlSpacing)
        let pushPull = max(available * pushPullFraction, minimumPushPullWidth)
        return ControlWidths(gauge: available - pushPull - controlSpacing, pushPull: pushPull)
    }
}

/// Card sizing for the carousel inside its quarter of the sheet.
///
/// The card used to be a fixed 104×132, which overflowed a quarter of a short
/// sheet and pushed the page dots out of the row. It now follows the height the
/// carousel actually has, keeping its 104:132 shape, capped so a tall sheet
/// does not blow the card up past the size the plate was designed for.
enum StockCarouselMetrics {
    /// The 12pt gap above the page dots plus the 6pt dot row.
    static let chromeHeight: CGFloat = 18
    static let minimumCardHeight: CGFloat = 64
    static let maximumCardHeight: CGFloat = 160
    /// The shipped card's 104×132 proportions.
    static let cardAspect: CGFloat = 104.0 / 132.0

    static func cardHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        min(max(height - chromeHeight, minimumCardHeight), maximumCardHeight)
    }

    static func cardWidth(forCardHeight height: CGFloat) -> CGFloat {
        height * cardAspect
    }
}
