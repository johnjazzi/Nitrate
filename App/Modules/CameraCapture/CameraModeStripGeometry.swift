import Foundation

/// A non-sizing canvas sibling in the shooting bar's existing lower centre.
/// The measured controls include their existing 8pt bottom padding.
enum CameraModeStripGeometry {
    static let height: CGFloat = 44

    static func frame(controls: CGRect, canvasWidth: CGFloat, horizontalInset: CGFloat) -> CGRect? {
        guard canvasWidth.isFinite, canvasWidth > 0, horizontalInset.isFinite, horizontalInset >= 0,
              controls.minY.isFinite, controls.height.isFinite, controls.height > 8 else { return nil }
        let width = min(200, canvasWidth - 2 * horizontalInset
                        - CameraControlGeometry.leftWidth - CameraControlGeometry.exposureWidth)
        let top = controls.maxY - height
        let shutterBottom = controls.minY + (controls.height - 8 + CameraControlGeometry.recordSize) / 2
        guard width >= 96, top >= shutterBottom else { return nil }
        return CGRect(x: (canvasWidth - width) / 2, y: top, width: width, height: height)
    }
}
