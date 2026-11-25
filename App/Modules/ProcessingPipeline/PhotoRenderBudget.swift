import CoreGraphics
import Foundation

/// The largest still this device can *deliver*, not merely decode.
///
/// The import side used to admit anything up to 80 MP while every downstream
/// still stage reused the camera's 12,192,768-pixel capture ceiling. A supported
/// 24 MP raw therefore previewed (the preview decodes at 960 px) and then threw
/// `Invalid still extent` part-way through development — after the operator had
/// picked it, paid the copy, and waited.
///
/// This is the one number the import gate, the RAW decoder and the still stage
/// all use now. It is deliberately the qualified raster rather than a memory
/// model: every still stage holds at least one full-frame `rgba16Float` texture
/// (8 bytes per pixel — ~98 MB at this size) and Core Image keeps several
/// intermediates alongside them, so the peak footprint is many frames at once.
/// 4032 x 3024 is the geometry this app has rendered end to end on a phone; a
/// larger frame is refused at import with the reason below instead of failing
/// mid-develop.
///
/// Raising it (for 24 MP, the next still size in circulation) is a hardware
/// qualification, not a constant edit: record peak footprint for the full
/// develop of a real 24 MP raw on the oldest supported phone, and only then move
/// this number. Full high-resolution tiled rendering is a separate project; it
/// is not what this budget does.
///
/// The camera's own capture budget (`PhotoCapturePolicy.maximumPixelCount`) is
/// unchanged and stays separate: it sizes the DNGs this app writes.
enum PhotoRenderBudget {
    static let maximumDeliverablePixels = 12_192_768

    /// Pixel count of a raster, saturating rather than trapping on overflow.
    static func pixelCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let result = width.multipliedReportingOverflow(by: height)
        return result.overflow ? Int.max : result.partialValue
    }

    static func accepts(width: Int, height: Int) -> Bool {
        let pixels = pixelCount(width: width, height: height)
        return pixels > 0 && pixels <= maximumDeliverablePixels
    }

    static func accepts(extent: CGSize) -> Bool {
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return false }
        return accepts(width: Int(extent.width.rounded()),
                       height: Int(extent.height.rounded()))
    }

    /// Megapixels as the operator reads them: 12.2 MP, 24.0 MP.
    static func megapixels(_ pixels: Int) -> String {
        String(format: "%.1f MP", Double(pixels) / 1_000_000)
    }

    /// One refusal, one wording, wherever it is raised: the import gate, the
    /// decoder, and the still stage all report the same reason, so a file cannot
    /// be turned away at one seam with a message that contradicts another.
    static func refusalMessage(width: Int, height: Int) -> String {
        let pixels = pixelCount(width: width, height: height)
        return "This RAW is \(width) × \(height) (\(megapixels(pixels))). "
            + "Nitrate develops stills up to \(megapixels(maximumDeliverablePixels)) on this device; "
            + "larger files need tiled rendering, which is not available yet."
    }
}
