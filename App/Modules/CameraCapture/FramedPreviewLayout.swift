import Foundation

/// Display-only 2:3 viewfinder crop; this never changes capture,
/// recorder or render dimensions.
enum FramedPreviewLayout {
    static let portraitAspect: CGFloat = 2.0 / 3.0

    static func previewRect(in canvas: CGRect, topControlsBottom: CGFloat,
                            bottomControlsTop: CGFloat, horizontalInset: CGFloat = 8,
                            controlGap: CGFloat = 8) -> CGRect {
        let width = max(0, canvas.width)
        let height = max(0, canvas.height)
        let inset = min(max(0, horizontalInset), width / 2)
        let gap = max(0, controlGap)
        let top = min(max(topControlsBottom + gap, canvas.minY), canvas.minY + height)
        let bottom = min(max(bottomControlsTop - gap, canvas.minY), canvas.minY + height)
        let availableWidth = max(0, width - 2 * inset)
        let availableHeight = max(0, bottom - top)
        let previewWidth = min(availableWidth, availableHeight * portraitAspect)
        let previewHeight = previewWidth / portraitAspect
        return CGRect(x: canvas.minX + (width - previewWidth) / 2,
                      y: top + (availableHeight - previewHeight) / 2,
                      width: previewWidth, height: previewHeight)
    }
}
