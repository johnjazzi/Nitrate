import AVFoundation
import CoreGraphics
import Foundation

/// How the *delivered* movie is framed relative to the recorded original.
///
/// The captured original is never cropped, resized or rewritten: the choice is
/// applied at render time as a centred crop of the decoded frame. The delivered
/// file is therefore the crop's own size and its pixels are the centre of the
/// original — not a squeezed copy of the whole frame.
///
/// 16:9 is the default and delivers exactly what the camera recorded. 4:3 keeps
/// the full recorded height and trims the sides, so a 3840x2160 original is
/// delivered as 2880x2160.
enum DeliveryFraming: String, Codable, CaseIterable, Sendable {
    case widescreen = "16:9"
    case fourThree = "4:3"

    /// `@AppStorage`/`UserDefaults` key. The stored value is the raw string
    /// above, so the file's own metadata speaks the same language as Settings.
    static let preferenceKey = "delivery.framing"

    /// Widescreen is the shipping default: an install that has never touched
    /// the row keeps delivering the full recorded frame.
    static let defaultValue: DeliveryFraming = .widescreen

    /// Missing, empty or unrecognised stored values fall back to the default
    /// rather than inventing a crop.
    static func resolved(_ raw: String?) -> DeliveryFraming {
        raw.flatMap(DeliveryFraming.init(rawValue:)) ?? defaultValue
    }

    /// The target aspect for a cropped delivery. Widescreen has no target: the
    /// recorded frame *is* the delivery.
    var deliveryAspect: Double? {
        switch self {
        case .widescreen: return nil
        case .fourThree: return 4.0 / 3.0
        }
    }

    /// Settings label. It states the delivered shape, not the request.
    var title: String {
        switch self {
        case .widescreen: return "16:9 Widescreen"
        case .fourThree: return "4:3 Crop"
        }
    }
}

extension DeliveryFraming {
    /// One resolved delivery geometry: the encoded size the renderer writes and
    /// the rectangle of the decoded source that fills it, in source pixels with
    /// the origin at the top-left of the decoded frame.
    struct Delivery: Equatable, Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let deliveredWidth: Int
        let deliveredHeight: Int
        let cropX: Int
        let cropY: Int

        /// True when the delivered frame is a strict sub-rectangle of the
        /// source. False means the full frame is written unchanged.
        var isCropped: Bool {
            cropX != 0 || cropY != 0
                || deliveredWidth != sourceWidth || deliveredHeight != sourceHeight
        }

        var deliveredSize: CGSize {
            CGSize(width: deliveredWidth, height: deliveredHeight)
        }

        var cropRect: CGRect {
            CGRect(x: cropX, y: cropY, width: deliveredWidth, height: deliveredHeight)
        }
    }

    /// Resolve the delivered size and the centred crop rectangle for a source
    /// size. `sourceWidth`/`sourceHeight` are the *encoded* track dimensions
    /// (`naturalSize`), not the rotated display size: rotation travels
    /// separately as the writer input's transform, so the crop is expressed in
    /// the same space the decoded and written frames live in.
    ///
    /// Rounding rule (deliberately simple and total):
    ///
    /// 1. Each source dimension is normalised to whole pixels by rounding to
    ///    the nearest integer (half away from zero).
    /// 2. Only a source **wider** than 4:3 is cropped. The crop keeps the full
    ///    source height and the width is `height × 4/3`, rounded to the nearest
    ///    whole pixel and then widened to the next even pixel. Evenness keeps
    ///    the 4:2:0 chroma grid aligned; the cost is at most one pixel of
    ///    aspect error, which is recorded as the delivered size itself.
    /// 3. A source at 4:3 or narrower is delivered unchanged. Widening would
    ///    upscale and letterboxing would add bars, and neither is a crop — so
    ///    the pass-through is the whole answer.
    /// 4. The crop is centred: the left edge is `(sourceWidth - width) / 2`, so
    ///    an odd remainder leaves one extra pixel on the right. The crop always
    ///    starts at the top of the frame.
    func delivery(forSourceSize size: CGSize) -> Delivery {
        let sourceWidth = Self.pixelDimension(size.width)
        let sourceHeight = Self.pixelDimension(size.height)
        guard sourceWidth > 0, sourceHeight > 0 else {
            return Delivery(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            deliveredWidth: 0, deliveredHeight: 0, cropX: 0, cropY: 0)
        }
        guard let aspect = deliveryAspect,
              Double(sourceWidth) > Double(sourceHeight) * aspect else {
            return Delivery(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            deliveredWidth: sourceWidth, deliveredHeight: sourceHeight,
                            cropX: 0, cropY: 0)
        }

        let requested = Self.evenPixelCount(Double(sourceHeight) * aspect)
        // Never wider than the source: a 4:3 source is a pass-through, and a
        // clamp that lands on an odd width is pulled back to even.
        var width = min(requested, sourceWidth)
        if width % 2 != 0 { width -= 1 }
        width = max(width, 1)
        // The crop is only real when it actually removes columns.
        guard width < sourceWidth else {
            return Delivery(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            deliveredWidth: sourceWidth, deliveredHeight: sourceHeight,
                            cropX: 0, cropY: 0)
        }
        return Delivery(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                        deliveredWidth: width, deliveredHeight: sourceHeight,
                        cropX: (sourceWidth - width) / 2, cropY: 0)
    }

    /// Whole pixels from a possibly fractional `naturalSize`; a non-finite or
    /// negative size resolves to zero so callers can refuse to render.
    private static func pixelDimension(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }

    /// Nearest whole pixel, widened to the next even pixel when that rounds to
    /// an odd count.
    private static func evenPixelCount(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = Int(value.rounded(.toNearestOrAwayFromZero))
        return rounded % 2 == 0 ? rounded : rounded + 1
    }
}

/// The movie writer's video output settings, kept pure so the delivered
/// geometry can be asserted without a Metal device, a source file or a writer.
///
/// The width/height here are the *delivered* dimensions from
/// `DeliveryFraming.Delivery`; the compression properties are unchanged from
/// the shipping encoder contract.
enum RenderVideoSettings {
    static func output(width: Int, height: Int, bitrate: Int,
                       nominalFrameRate: Float) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType(rawValue: RenderEncodingContract.codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 48,
                AVVideoExpectedSourceFrameRateKey: nominalFrameRate,
                // Offline encoding can use B-frames to spend the fixed bitrate
                // more efficiently on stochastic detail such as film grain.
                AVVideoAllowFrameReorderingKey: true
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: RenderEncodingContract.colorPrimaries,
                AVVideoTransferFunctionKey: RenderEncodingContract.transferFunction,
                AVVideoYCbCrMatrixKey: RenderEncodingContract.yCbCrMatrix
            ]
        ]
    }
}
