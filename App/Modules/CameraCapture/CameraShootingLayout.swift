import SwiftUI

/// Coordinates are inside the bar's existing 16pt horizontal margins. Exposure
/// owns the height; neither its ruler nor its type is compressed to fit the LCD.
///
/// The LCD takes the upper two thirds so a confirmed take and the remaining time
/// read at a glance. The stock selector and the print gauge share the recessed
/// well that fills the lower third.
struct CameraControlGeometry {
    static let leftWidth: CGFloat = 88
    static let exposureWidth: CGFloat = 92
    static let recordSize: CGFloat = 84
    static let columnGap: CGFloat = 6

    let lcd: CGRect
    /// The recessed stock/gauge well — one slot for both controls.
    let stock: CGRect
    let record: CGRect
    let exposure: CGRect

    init(width: CGFloat, height: CGFloat) {
        let wellHeight = (height - Self.columnGap) / 3
        let lcdHeight = height - Self.columnGap - wellHeight
        lcd = CGRect(x: 0, y: 0, width: Self.leftWidth, height: lcdHeight)
        stock = CGRect(x: 0, y: lcdHeight + Self.columnGap,
                       width: Self.leftWidth, height: wellHeight)
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
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let exposure = subviews[3].sizeThatFits(ProposedViewSize(width: CameraControlGeometry.exposureWidth, height: nil))
        return CGSize(width: proposal.width ?? 288, height: exposure.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let geometry = CameraControlGeometry(width: bounds.width, height: bounds.height)
        let frames = [geometry.stock, geometry.lcd, geometry.record, geometry.exposure]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
