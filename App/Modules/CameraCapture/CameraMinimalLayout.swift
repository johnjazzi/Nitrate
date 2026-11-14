import CoreGraphics

/// Layout-only measurements; changing placement cannot reconfigure the camera
/// or change the preview's measured shooting-bar height.
enum CameraMinimalLayout {
    static let lensFaceSize: CGFloat = 30
    static let lensHitSize: CGFloat = 44


    static func lensRow(in controls: CGRect, canvasWidth: CGFloat, lensCount: Int) -> CGRect? {
        guard lensCount > 0, lensCount <= 4, canvasWidth.isFinite,
              controls.minY.isFinite, controls.minY >= lensHitSize + 8 else { return nil }
        let width = CGFloat(lensCount) * lensHitSize
        guard canvasWidth >= width + 16 else { return nil }
        // Above the bar, never over the exposure column's hit area.
        return CGRect(x: (canvasWidth - width) / 2, y: controls.minY - lensHitSize - 4,
                      width: width, height: lensHitSize)
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
