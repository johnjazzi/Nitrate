import SwiftUI

/// Coordinates are inside the bar's current horizontal margins, which match the
/// framed viewfinder's side edges plus 4pt of padding in Frame Mode and the immersive 16pt margin
/// otherwise. Exposure owns the height; neither its ruler nor its type is
/// compressed to fit the LCD.
///
/// Stock and gauge sit beside the shutter; the quiet queue/remaining-time
/// readout follows beneath them. Neither left-hand slot sets the bar height.
struct CameraControlGeometry {
    static let leftWidth: CGFloat = 84
    static let exposureWidth: CGFloat = 84
    static let recordSize: CGFloat = 84
    static let columnGap: CGFloat = 6

    /// The immersive shooting bar's established horizontal margin.
    static let defaultHorizontalInset: CGFloat = 16
    static let selectorEdgePadding: CGFloat = 4

    /// The narrowest bar content that keeps the left column, the centred REC and
    /// the exposure column clear of each other: the wider side column twice, REC,
    /// and a `columnGap` on each side.
    static let minimumRowWidth: CGFloat =
        max(leftWidth, exposureWidth) * 2 + recordSize + columnGap * 2

    /// The horizontal margin that lines the bar's outer LCD/stock and exposure
    /// edges up with a framed viewfinder's side edges.
    ///
    /// `previewEdgeInset` is the preview's `minX` measured from the canvas
    /// leading edge; because the preview is centred, this equals its trailing
    /// gap. The result is clamped so the bar content never falls below
    /// `minimumRowWidth` — where a narrow phone or a landscape hold cannot align
    /// exactly — and never goes negative. A zero canvas or a zero preview falls
    /// back to `defaultHorizontalInset`, so the bar keeps the immersive margin
    /// on the first frame before its bounds are known.
    static func controlBarHorizontalInset(previewEdgeInset: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        guard canvasWidth > 0, previewEdgeInset > 0 else { return defaultHorizontalInset }
        let widest = max(0, (canvasWidth - minimumRowWidth) / 2)
        return min(previewEdgeInset + selectorEdgePadding, widest)
    }

    let lcd: CGRect
    /// One flat entry point for stock and gauge.
    let stock: CGRect
    let record: CGRect
    let exposure: CGRect

    init(width: CGFloat, height: CGFloat, style: CameraUIStyle = .minimal) {
        if style == .classic {
            let wellHeight = (height - Self.columnGap) / 3
            let lcdHeight = height - Self.columnGap - wellHeight
            lcd = CGRect(x: 0, y: 0, width: Self.leftWidth, height: lcdHeight)
            stock = CGRect(x: 0, y: lcdHeight + Self.columnGap, width: Self.leftWidth, height: wellHeight)
        } else {
            let stockTop = max(48, (height - Self.recordSize) / 2)
            stock = CGRect(x: 0, y: stockTop, width: Self.leftWidth, height: 44)
            let lcdTop = stock.maxY + Self.columnGap
            lcd = CGRect(x: 0, y: lcdTop, width: Self.leftWidth, height: max(44, height - lcdTop))
        }
        record = CGRect(x: (width - Self.recordSize) / 2, y: (height - Self.recordSize) / 2,
                        width: Self.recordSize, height: Self.recordSize)
        exposure = CGRect(x: width - Self.exposureWidth, y: 0,
                          width: Self.exposureWidth, height: height)
    }

    static func faceSize(in slot: CGSize, degrees: Double) -> CGSize {
        abs(degrees) == 90 ? CGSize(width: slot.height, height: slot.width) : slot
    }
}

/// Ordered children: stock/gauge well, LCD, REC, exposure. The measured full
/// exposure height is the shared height, including its unchanged 120pt ruler
/// track.
struct CameraShootingLayout: Layout {
    var style: CameraUIStyle = .minimal

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let exposure = subviews[3].sizeThatFits(ProposedViewSize(width: CameraControlGeometry.exposureWidth, height: nil))
        return CGSize(width: proposal.width ?? 288, height: exposure.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let geometry = CameraControlGeometry(width: bounds.width, height: bounds.height, style: style)
        let frames = [geometry.stock, geometry.lcd, geometry.record, geometry.exposure]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
