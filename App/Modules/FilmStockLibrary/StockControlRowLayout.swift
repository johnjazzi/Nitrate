import CoreGraphics

/// Width budget for the stock sheet's single control row: stock, gauge and
/// push/pull side by side.
///
/// The three choices that define a render used to be stacked, and the push/pull
/// picker fell below the fold on a phone — the operator never saw it. They now
/// share one row, so the split has to be arithmetic rather than whatever the
/// controls negotiate: push/pull is pinned to a fifth of the row, and stock and
/// gauge divide the rest with floors that keep the four gauge segments and a
/// stock name legible on a 320pt phone. Kept free of SwiftUI so the split can be
/// checked at every phone width without rendering.
enum StockControlRowLayout {
    /// Gap between the three cells.
    static let spacing: CGFloat = 8
    /// Share of the row the push/pull dropdown takes.
    static let pushPullFraction: CGFloat = 0.2
    /// Push/pull floor. A fifth of a 288pt row is 57.6pt, which already clears
    /// this, so the fraction — not the floor — decides every phone width.
    static let minimumPushPullWidth: CGFloat = 56
    /// Gauge floor: four segments at 30pt still read "35".
    static let minimumGaugeWidth: CGFloat = 120
    /// Stock floor: a swatch plus a truncated stock name.
    static let minimumStockWidth: CGFloat = 88
    /// Share of the space left after push/pull that the gauge takes; the stock
    /// dropdown takes the remainder, because stock names are the longest text.
    static let gaugeShare: CGFloat = 0.55

    /// Caption line plus the 34pt control, so the row has one fixed height and
    /// the preview above it can claim everything else.
    static let rowHeight: CGFloat = 54

    struct Widths: Equatable {
        var stock: CGFloat
        var gauge: CGFloat
        var pushPull: CGFloat

        /// The width the three cells plus their two gaps occupy.
        var total: CGFloat { stock + gauge + pushPull + StockControlRowLayout.spacing * 2 }
    }

    /// Split `width` into the three cell widths. Always sums to `width`, so no
    /// cell is pushed past the edge of the row.
    static func widths(forAvailableWidth width: CGFloat) -> Widths {
        let available = max(width, minimumStockWidth + minimumGaugeWidth + minimumPushPullWidth + spacing * 2)
        let pushPull = max(available * pushPullFraction, minimumPushPullWidth)
        let remainder = available - pushPull - spacing * 2
        let gauge = min(max(remainder * gaugeShare, minimumGaugeWidth),
                        max(remainder - minimumStockWidth, minimumGaugeWidth))
        return Widths(stock: remainder - gauge, gauge: gauge, pushPull: pushPull)
    }
}
