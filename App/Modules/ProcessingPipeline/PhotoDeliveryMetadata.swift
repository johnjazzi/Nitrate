import CoreGraphics
import Foundation
import ImageIO

/// Tags a developed still with the same Nitrate metadata a movie carries.
///
/// A JPEG has no QuickTime keyspace, so the shared `com.filmemulation.*` payload
/// travels in EXIF UserComment as JSON while the consumer-visible fields use the
/// tags photo apps actually display: the IPTC caption and keywords. Both writers
/// build the payload from
/// `RenderMovieMetadata.recipeValues`, so a photo and a movie from the same stock
/// stay comparable instead of drifting apart.
enum PhotoDeliveryMetadata {
    /// The still's own exposure, when the DNG reports it. A photo is one
    /// exposure, so the movie's nominal shutter angle and frame rate are omitted
    /// rather than invented; the real shutter and ISO travel instead.
    struct StillCapture: Equatable, Sendable {
        var exposureSeconds: Double?
        var iso: Int?
        /// EXIF orientation of the stored DNG. The photo connection's rotation
        /// angle is installed immediately before the capture, so this is the
        /// orientation the DNG itself reports; `CIRAWFilter` uprights it on
        /// decode and the renderer must not rotate again.
        var orientation: Int = 1

        /// `1/500` from 0.002 s. Nil for a missing or non-finite value.
        var shutterDenominator: Int? {
            guard let exposureSeconds, exposureSeconds.isFinite, exposureSeconds > 0 else { return nil }
            return max(1, Int((1 / exposureSeconds).rounded()))
        }
    }

    /// Keys the movie writer states that describe a take, not a still.
    static let movieOnlyKeys: Set<String> = [
        "shutter-angle", "capture-frame-rate", "encoding-bitrate-target"
    ]

    /// Read the as-shot exposure straight from the DNG. Absent EXIF leaves both
    /// fields nil; the payload then carries no capture-exposure claim at all.
    static func capture(fromDNG url: URL) -> StillCapture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return StillCapture()
        }
        let exposure = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return StillCapture(exposureSeconds: exposure, iso: iso, orientation: orientation)
    }

    /// ImageIO properties for the delivered JPEG, merged over the encoder's own
    /// compression settings by the caller.
    static func properties(config: FilmStockConfig, capture: StillCapture,
                           deliveredSize: CGSize) throws -> [CFString: Any] {
        let orientation = RenderDeliveryOrientation.from(naturalSize: deliveredSize,
                                                        preferredTransform: .identity)
        let caption = RenderConsumerMetadata.caption(stockName: config.displayName,
                                                     gauge: config.effectivePrintGauge.rawValue)
        var overrides: [String: String] = ["encoding-codec": "jpeg"]
        if let denominator = capture.shutterDenominator {
            overrides["shutter-speed"] = "1/\(denominator)"
        }
        if let iso = capture.iso, iso > 0 {
            overrides["iso"] = String(iso)
            overrides["iso-role"] = "capture-exposure-index"
        }
        let values = try RenderMovieMetadata.recipeValues(config: config,
            overrides: overrides, omitting: movieOnlyKeys)
        let payload = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])

        var exif: [CFString: Any] = [
            kCGImagePropertyExifUserComment: String(decoding: payload, as: UTF8.self)
        ]
        if let iso = capture.iso, iso > 0 { exif[kCGImagePropertyExifISOSpeedRatings] = [iso] }
        if let seconds = capture.exposureSeconds, seconds.isFinite, seconds > 0 {
            exif[kCGImagePropertyExifExposureTime] = seconds
        }
        return [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: caption,
                kCGImagePropertyIPTCKeywords: RenderConsumerMetadata.keywords(orientation: orientation)
            ] as [CFString: Any],
            // No TIFF dictionary: ImageIO drops it for JPEG (verified by
            // writing and reading the file back), so the caption above is the
            // one description a photo app actually gets.
            kCGImagePropertyExifDictionary: exif
        ]
    }
}
