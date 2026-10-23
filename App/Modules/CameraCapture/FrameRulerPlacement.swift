import CoreGraphics
import SwiftUI

/// Bounded placement for the rulers that live inside the frame.
///
/// The capture canvas is portrait-locked, so a physical edge maps to a
/// different canvas edge once the phone is held sideways. This mirrors the
/// established `ManualControlsOverlayGeometry` convention (a +90° hold maps the
/// portrait right edge to the physical top). Both rulers now hug a physical
/// side edge: the zoom ruler the physical left, the manual-focus ruler the
/// physical right. Everything here is pure geometry derived from the preview
/// rectangle and the measured control bounds; it never reads a ruler's own
/// size, so a ruler can never feed back into the preview.
enum FrameRulerPlacementGeometry {
    static let focusThickness: CGFloat = 44
    static let zoomThickness: CGFloat = 44

    /// No gap between the ruler's slot and the live preview frame: the rail
    /// sits flush against the frame's physical side edge, so the 44pt touch
    /// footprint still starts exactly at the preview boundary.
    static let margin: CGFloat = 0

    /// The visible rail the in-frame rulers draw: 80% of the 44pt touch
    /// footprint (35.2pt). The narrower rail is inset inside the 44pt slot —
    /// flush to the frame edge, with the remainder on the frame-interior side —
    /// so the drawn rail is slimmer while the tap target keeps its 44pt width.
    static let visualFraction: CGFloat = 0.8
    static let rulerVisualThickness: CGFloat = focusThickness * visualFraction

    /// The side edge of the physical frame the ruler hugs.
    enum PhysicalEdge: Equatable {
        /// The frame's physical left edge (the zoom ruler).
        case left
        /// The frame's physical right edge (the focus ruler).
        case right
    }

    /// The canvas edge that carries a physical edge for a given quarter turn.
    enum CanvasEdge: Equatable {
        case left, right, top, bottom
    }

    /// Canvas edge for `edge` at `orientationDegrees`. Portrait (0°) keeps the
    /// physical left on the canvas left and the physical right on the canvas
    /// right; a +90° hold puts the physical right on the canvas bottom and the
    /// physical left on the canvas top; a -90° hold is the mirror image.
    static func canvasEdge(for edge: PhysicalEdge, orientationDegrees: Double) -> CanvasEdge {
        switch (edge, normalized(orientationDegrees)) {
        case (.right, 0): return .right
        case (.right, 90): return .bottom
        case (.right, -90): return .top
        case (.right, 180): return .left
        case (.left, 0): return .left
        case (.left, 90): return .top
        case (.left, -90): return .bottom
        case (.left, 180): return .right
        default: return edge == .right ? .right : .left
        }
    }

    /// The largest rectangle of the requested thickness that sits along the
    /// physical `edge` of `frame`, inset by `margin` on every side. `margin`
    /// defaults to zero so the slot runs flush to the live preview frame edge.
    /// Returns `.null` for a degenerate frame so the caller can skip the ruler.
    static func rect(inFrame originalFrame: CGRect, edge: PhysicalEdge, thickness: CGFloat,
                     orientationDegrees: Double, margin: CGFloat = margin) -> CGRect {
        guard originalFrame.width.isFinite, originalFrame.height.isFinite,
              originalFrame.minX.isFinite, originalFrame.minY.isFinite,
              thickness.isFinite, thickness > 0, margin.isFinite, margin >= 0 else { return .null }
        let frame = originalFrame
        let canvasEdge = canvasEdge(for: edge, orientationDegrees: orientationDegrees)
        let isVertical = canvasEdge == .left || canvasEdge == .right
        let run = max(0, (isVertical ? frame.height : frame.width) - 2 * margin)
        let cross = (isVertical ? frame.width : frame.height) - 2 * margin
        guard run >= 44, cross >= thickness else { return .null }
        switch canvasEdge {
        case .right:
            return CGRect(x: frame.maxX - margin - thickness, y: frame.minY + margin,
                          width: thickness, height: run)
        case .left:
            return CGRect(x: frame.minX + margin, y: frame.minY + margin,
                          width: thickness, height: run)
        case .bottom:
            return CGRect(x: frame.minX + margin, y: frame.maxY - margin - thickness,
                          width: run, height: thickness)
        case .top:
            return CGRect(x: frame.minX + margin, y: frame.minY + margin,
                          width: run, height: thickness)
        }
    }

    /// Reduce any angle to its equivalent in (-180, 180], leaving non-finite
    /// input at 0 so a bad sensor read cannot place a ruler off-frame.
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var remainder = degrees.truncatingRemainder(dividingBy: 360)
        if remainder > 180 { remainder -= 360 }
        if remainder <= -180 { remainder += 360 }
        return remainder == 0 ? 0 : remainder
    }
}

/// Places one ruler along a physical frame edge. The content is authored in the
/// upright portrait axis; a ±90° hold turns the whole slot so the ruler keeps
/// the physical edge it was asked for while its glyphs stay readable — the same
/// single-outer-rotation pattern as `ManualControlsOverlay`. The slot is clipped
/// to its rectangle, so content that would overflow cannot paint or take taps
/// outside the granted slot.
struct FrameRulerSlot<Content: View>: View {
    let rect: CGRect
    let rotationDegrees: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        let landscape = abs(rotationDegrees) == 90
        let authored = CGSize(width: landscape ? rect.height : rect.width,
                              height: landscape ? rect.width : rect.height)
        content()
            .frame(width: authored.width, height: authored.height)
            .rotationEffect(.degrees(rotationDegrees))
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .position(x: rect.midX, y: rect.midY)
    }
}
