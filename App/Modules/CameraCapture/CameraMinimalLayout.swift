import CoreGraphics

/// Layout-only measurements; changing placement cannot reconfigure the camera
/// or change the preview's measured shooting-bar height.
enum CameraMinimalLayout {
    static let lensFaceSize: CGFloat = 30
    static let lensHitSize: CGFloat = 44
    static let lensFaceGap: CGFloat = 4

    /// Compact choices share one 44pt-high strip, with unambiguous adjoining cells.
    static func lensCellWidth(style: CameraUIStyle) -> CGFloat {
        lensFaceSize + lensFaceGap
    }


    static func lensRow(in controls: CGRect, canvasWidth: CGFloat, lensCount: Int,
                        style: CameraUIStyle = .minimal, previewBottom: CGFloat? = nil) -> CGRect? {
        guard lensCount > 0, lensCount <= 4, canvasWidth.isFinite,
              controls.minY.isFinite, controls.height.isFinite, controls.height > 8 else { return nil }
        let width = CGFloat(lensCount) * lensCellWidth(style: style)
        guard canvasWidth >= width + 16 else { return nil }
        // Controls include 8pt bottom padding. Use the actual shutter's top,
        // not the top of the whole shooting bar (which put lenses over footage).
        let shutterTop = controls.minY + (controls.height - 8 - CameraControlGeometry.recordSize) / 2
        let top = shutterTop - lensHitSize - 4
        guard top >= 0 else { return nil }
        if let previewBottom {
            guard previewBottom.isFinite, top >= previewBottom + 2 else { return nil }
        }
        return CGRect(x: (canvasWidth - width) / 2, y: top, width: width, height: lensHitSize)
    }

    static func exposureMeter(in preview: CGRect, above lensRow: CGRect? = nil) -> CGRect? {
        guard !preview.isNull, !preview.isEmpty,
              preview.width.isFinite, preview.height.isFinite,
              preview.width >= 160, preview.height >= 60 else { return nil }
        let width = min(220, preview.width - 96)
        let bottom = min(preview.maxY - 10, lensRow.map { $0.minY - 8 } ?? preview.maxY)
        guard bottom - 36 >= preview.minY else { return nil }
        return CGRect(x: preview.midX - width / 2, y: bottom - 36,
                      width: width, height: 36)
    }

    static func pinchRuler(in preview: CGRect, avoiding overlays: [CGRect]) -> CGRect? {
        guard !preview.isNull, !preview.isEmpty, preview.width >= 100 else { return nil }
        let bottom = overlays.reduce(preview.maxY - 10) { min($0, $1.minY - 8) }
        guard bottom - 60 >= preview.minY else { return nil }
        return CGRect(x: preview.minX + 16, y: bottom - 60, width: preview.width - 32, height: 60)
    }
}
