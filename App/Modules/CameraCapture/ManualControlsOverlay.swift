import SwiftUI

/// Coordinates belong to the safe-area viewport, independent of preview framing.
enum ManualControlsOverlayGeometry {
    static func availableRect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat,
                              excluding status: CGRect? = nil) -> CGRect {
        let top = min(max(toolbarBottom + 6, 0), viewport.height)
        let bottom = min(max(controlsTop - 6, top), viewport.height)
        let left = status.map { $0.midX < viewport.width / 2 ? $0.maxX + 8 : 16 } ?? 16
        let right = status.map { $0.midX > viewport.width / 2 ? $0.minX - 8 : viewport.width - 16 }
            ?? viewport.width - 16
        return CGRect(x: left, y: top, width: max(0, right - left), height: bottom - top)
    }

    static func faceSize(expanded: Bool, rotationDegrees: Double) -> CGSize {
        let landscape = abs(rotationDegrees) == 90
        return CGSize(width: landscape ? (expanded ? 500 : 400) : (expanded ? 360 : 304),
                      height: expanded ? 330 : 164)
    }

    static func rect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat,
                     excluding status: CGRect? = nil, expanded: Bool = false,
                     rotationDegrees: Double = 0) -> CGRect {
        let available = availableRect(viewport: viewport, toolbarBottom: toolbarBottom,
                                      controlsTop: controlsTop, excluding: status)
        let face = faceSize(expanded: expanded, rotationDegrees: rotationDegrees)
        let landscape = abs(rotationDegrees) == 90
        let width = min(available.width, landscape ? face.height : face.width)
        let height = min(available.height, landscape ? face.width : face.height)
        // In a portrait-locked canvas +90° maps portrait right to the
        // physical top. Put the panel on the opposite edge in that hold;
        // -90° already maps the portrait right edge to physical bottom.
        let x = landscape && rotationDegrees > 0 ? available.minX : available.maxX - width
        return CGRect(x: x, y: available.minY, width: width, height: height)
    }
}

/// Only this complete face rotates: background, scroll viewport and hit targets.
/// Its swapped bounds are reserved before placement; it cannot size the preview.
struct ManualControlsOverlay<Content: View>: View {
    let viewport: CGSize
    let toolbarBottom: CGFloat
    let controlsTop: CGFloat
    var excluding: CGRect?
    var expanded = false
    var rotationDegrees: Double = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        let rect = ManualControlsOverlayGeometry.rect(viewport: viewport, toolbarBottom: toolbarBottom,
                                                      controlsTop: controlsTop, excluding: excluding,
                                                      expanded: expanded, rotationDegrees: rotationDegrees)
        let landscape = abs(rotationDegrees) == 90
        let face = CGSize(width: landscape ? rect.height : rect.width,
                          height: landscape ? rect.width : rect.height)
        ScrollView([.horizontal, .vertical]) {
            content()
                .frame(width: max(face.width, landscape ? 360 : 280))
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .frame(width: face.width, height: face.height, alignment: .topLeading)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .rotationEffect(.degrees(rotationDegrees))
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}
