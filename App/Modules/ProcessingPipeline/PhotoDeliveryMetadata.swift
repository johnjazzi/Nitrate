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
    /// rather than invented; the real shutter and ISO travel instead, together
    /// with the lens, aperture and focal length the DNG knows.
    struct StillCapture: Equatable, Sendable {
        var exposureSeconds: Double?
        var iso: Int?
        /// Aperture as the lens's f-number, e.g. 3.99932.
        var fNumber: Double?
        /// Lens description as the DNG reports it, e.g. "iPhone 16 Pro back triple camera".
        var lensModel: String?
        var focalLengthMM: Double?
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

    /// Keys a still states for itself, because a still renders the same recipe
    /// through a smaller share of it (`stillHalationScale`, `stillDiffusionScale`)
    /// and after a RAW decode lift. They are present in both payloads and are
    /// expected to disagree.
    static let stillAppliedKeys: Set<String> = [
        "diffusion-amount", "diffusion-still-scale", "halation-still-scale",
        "halation-scene-lift-ev"
    ]

    /// Keys the movie writer states that describe a take, not a still.
    static let movieOnlyKeys: Set<String> = [
        "shutter-angle", "capture-frame-rate", "encoding-bitrate-target"
    ]

    /// Read the as-shot exposure straight from the DNG. Absent EXIF leaves the
    /// fields nil; the payload then carries no capture-exposure claim at all.
    static func capture(fromDNG url: URL) -> StillCapture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return StillCapture()
        }
        let exposure = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        let focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
        let lens = (exif[kCGImagePropertyExifLensModel] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return StillCapture(exposureSeconds: exposure, iso: iso,
                            fNumber: fNumber, lensModel: lens.flatMap { $0.isEmpty ? nil : $0 },
                            focalLengthMM: focalLength, orientation: orientation)
    }

    /// ImageIO properties for the delivered JPEG, merged over the encoder's own
    /// compression settings by the caller.
    /// - Parameter raw: the DNG's own sensor numbers, when the delivered file
    ///   came from one. Reported only; nothing branches on them.
    /// - Parameter sceneLiftStops: how far the decode lifted this frame, which
    ///   is also the factor the halation knees were scaled by. Recorded so a
    ///   render can be audited instead of trusted.
    static func properties(config: FilmStockConfig, capture: StillCapture,
                           deliveredSize: CGSize,
                           raw: DNGMetadata? = nil,
                           sceneLiftStops: Float? = nil) throws -> [CFString: Any] {
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
        if let fNumber = capture.fNumber, fNumber.isFinite, fNumber > 0 {
            overrides["aperture-f-number"] = String(fNumber)
        }
        if let lens = capture.lensModel {
            overrides["lens"] = lens
        }
        if let focalLength = capture.focalLengthMM, focalLength.isFinite, focalLength > 0 {
            overrides["focal-length-mm"] = String(focalLength)
        }
        if let sceneLiftStops, sceneLiftStops.isFinite, sceneLiftStops != 0 {
            overrides["halation-scene-lift-ev"] = String(format: "%.2f", sceneLiftStops)
        }
        // The base exposure every still gets, so a delivered file says what it
        // was lifted by rather than leaving it to be inferred.
        overrides["photo-exposure-ev"] = String(format: "%.2f", RAWPhotoDecoder.baseExposureEV)
        // The shares the still render applied, and the amount actually mixed:
        // the recipe's keys describe the take, so a photo states its own.
        overrides["halation-still-scale"] = String(format: "%.2f", config.effectiveStillHalationScale)
        overrides["diffusion-still-scale"] = String(format: "%.2f", config.effectiveStillDiffusionScale)
        overrides["diffusion-amount"] = String(format: "%.2f", config.effectiveStillDiffusion.amount)
        if let whiteLevel = raw?.usableWhiteLevel {
            overrides["raw-white-level"] = String(format: "%.0f", whiteLevel)
        }
        if let model = raw?.model ?? raw?.uniqueCameraModel {
            overrides["raw-camera-model"] = model
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
        // Photo apps read the capture fields from EXIF, not from the payload.
        if let fNumber = capture.fNumber, fNumber.isFinite, fNumber > 0 {
            exif[kCGImagePropertyExifFNumber] = fNumber
        }
        if let lens = capture.lensModel {
            exif[kCGImagePropertyExifLensModel] = lens
        }
        if let focalLength = capture.focalLengthMM, focalLength.isFinite, focalLength > 0 {
            exif[kCGImagePropertyExifFocalLength] = focalLength
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
