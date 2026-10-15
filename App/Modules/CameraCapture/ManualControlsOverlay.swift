import SwiftUI

/// Coordinates are local to the safe-area viewport, never the physical screen.
/// Manual help is deliberately excluded from the stationary framing geometry.
enum ManualControlsOverlayGeometry {
    static func rect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat) -> CGRect {
        let top = min(max(toolbarBottom + 6, 0), viewport.height)
        let bottom = min(max(controlsTop - 6, top), viewport.height)
        return CGRect(x: 16, y: top, width: max(0, viewport.width - 32), height: bottom - top)
    }
}

/// A non-sizing sibling above the preview, bounded even with help expanded.
/// The scroll viewport clips long content, not the camera or toolbar.
struct ManualControlsOverlay<Content: View>: View {
    let viewport: CGSize
    let toolbarBottom: CGFloat
    let controlsTop: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        let rect = ManualControlsOverlayGeometry.rect(viewport: viewport, toolbarBottom: toolbarBottom,
                                                      controlsTop: controlsTop)
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
