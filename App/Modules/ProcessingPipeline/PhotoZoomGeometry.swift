import CoreGraphics

/// Pure geometry for post-decode, Bayer-safe digital photo zoom.
enum PhotoZoomGeometry {
    static let minimumZoom = 1.0
    static let maximumZoom = 4.0

    static func isSupported(_ zoom: Double) -> Bool {
        zoom.isFinite && zoom >= minimumZoom && zoom <= maximumZoom
    }

    /// Centers a native-resolution crop in the oriented decoded extent.
    static func centeredCrop(in extent: CGRect, zoom: Double) -> CGRect? {
        guard isSupported(zoom), extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { return nil }
        let width = max(1, floor(extent.width / zoom))
        let height = max(1, floor(extent.height / zoom))
        let x = floor(extent.midX - width / 2)
        let y = floor(extent.midY - height / 2)
        return CGRect(x: x, y: y, width: width, height: height).intersection(extent.integral)
    }
}
