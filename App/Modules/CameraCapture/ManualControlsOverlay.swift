import SwiftUI

/// Coordinates are local to the safe-area viewport, never the physical screen.
/// Manual help is deliberately excluded from the stationary framing geometry.
enum ManualControlsOverlayGeometry {
    static func rect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat,
                     excluding status: CGRect? = nil) -> CGRect {
        let top = min(max(toolbarBottom + 6, 0), viewport.height)
        let bottom = min(max(controlsTop - 6, top), viewport.height)
        // Keep the expanded/help scroll viewport clear of the physical-top rail.
        let left = status.map { $0.midX < viewport.width / 2 ? $0.maxX + 8 : 16 } ?? 16
        let right = status.map { $0.midX > viewport.width / 2 ? $0.minX - 8 : viewport.width - 16 }
            ?? viewport.width - 16
        return CGRect(x: left, y: top, width: max(0, right - left), height: bottom - top)
    }
}

/// A non-sizing sibling above the preview, bounded even with help expanded.
/// The scroll viewport clips long content, not the camera or toolbar.
struct ManualControlsOverlay<Content: View>: View {
    let viewport: CGSize
    let toolbarBottom: CGFloat
    let controlsTop: CGFloat
    var excluding: CGRect?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let rect = ManualControlsOverlayGeometry.rect(viewport: viewport, toolbarBottom: toolbarBottom,
                                                      controlsTop: controlsTop, excluding: excluding)
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}
