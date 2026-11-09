import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Reads only local technical properties and our explicitly allowed export tags.
/// Poster creation is best effort and never participates in Photos authorization.
enum RenderReceiptService {
    private static let metadataKeys: Set<String> = Set([
        "film-stock", "stock-name", "lut", "light-type", "iso", "iso-role",
        "halation-level", "glow-level", "halation-radius-fraction", "halation-tint",
        "grain-size", "recipe-version", "print-gauge", "grain-size-effective",
        "grain-gauge-amplitude", "grain-algorithm", "grain-edge-boost-multiplier",
        "shutter-speed", "shutter-angle", "capture-frame-rate",
        "encoding-codec", "encoding-bitrate-target",
        "color-contract-verified", "render-settings-schema", "render-settings",
        "source-color-validation", "capture-color-space", "source-color-test-bypass",
        // Push/pull is written by the movie and still writers alike; the receipt
        // must read it back so the metadata cards state what the file states.
        "push-pull", "push-pull-stops", "push-pull-mode", "push-pull-linear-gain",
        "push-pull-metered-offset-ev",
        // The lamp: the receipt must read the same capture facts the file states.
        "flash-mode", "flash-intensity-percent", "flash-duration-percent",
        "flash-exposure-seconds", "flash-refused", "flash-refused-reason",
        // Colour, balance, lens and slate cards.
        "color-space", "white-balance-kelvin", "wb-tint",
        "aperture-f-number", "lens", "focal-length-mm",
        "reel", "scene", "take"
    ].map { "com.filmemulation." + $0 })

    private static let keyPrefix = "com.filmemulation."
    /// One value, matching the movie path's per-item bound.
    private static let maximumValueBytes = 16_384
    /// A JPEG has no item list, so the whole payload is one EXIF string. The cap
    /// keeps a malformed or hostile comment from being parsed at arbitrary size.
    private static let maximumPayloadBytes = 65_536

    static func capture(url: URL, originalURL: URL? = nil, renderDurationSeconds: Double?,
                        includeThumbnail: Bool = true,
                        maximumThumbnailSize: Int = 320) async -> RenderReceipt {
        // Durable result zoom is a bounded delivered still, never the full movie.
        let thumbnailSize = min(max(maximumThumbnailSize, 1), 1600)
        var receipt = RenderReceipt(renderDurationSeconds: renderDurationSeconds)
        receipt.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        receipt.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        receipt.fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        // Read the original while it is still on disk: cleanup removes it after
        // delivery, and a cleaned-up job must not later invent these values.
        if let originalURL, let original = await originalProperties(at: originalURL) {
            receipt.original = original
        }
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            receipt.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            receipt.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            receipt.codec = CGImageSourceGetType(imageSource) as String?
            // A JPEG has no QuickTime item list: the shared recipe travels in
            // EXIF UserComment. Without this the still's receipt showed every
            // recipe field as unavailable while the movie's did not.
            receipt.metadata = stillMetadata(inImageProperties: properties)
            if includeThumbnail, let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize
            ] as CFDictionary) { receipt.thumbnailJPEG = jpeg(thumbnail, maximumSize: thumbnailSize) }
            return receipt
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds >= 0 {
            receipt.durationSeconds = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let upright = CGRect(origin: .zero, size: size).applying(transform)
                if upright.width.isFinite, upright.height.isFinite,
                   abs(upright.width) > 0, abs(upright.height) > 0,
                   abs(upright.width) < 1_000_000, abs(upright.height) < 1_000_000 {
                    receipt.pixelWidth = Int(abs(upright.width).rounded())
                    receipt.pixelHeight = Int(abs(upright.height).rounded())
                }
            }
            if let fps = try? await track.load(.nominalFrameRate), fps.isFinite, fps > 0 {
                receipt.framesPerSecond = Double(fps)
            }
            if let description = try? await track.load(.formatDescriptions).first {
                let code = CMFormatDescriptionGetMediaSubType(description)
                let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                             UInt8((code >> 8) & 255), UInt8(code & 255)]
                receipt.codec = String(bytes: bytes, encoding: .ascii)
            }
        }
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard item.keySpace == .quickTimeMetadata,
                      let key = item.key as? String, metadataKeys.contains(key),
                      let value = try? await item.load(.stringValue),
                      value.utf8.count <= maximumValueBytes else { continue }
                receipt.metadata[key] = value
            }
        }
        guard includeThumbnail else { return receipt }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        if let result = try? await generator.image(at: .zero) {
            receipt.thumbnailJPEG = jpeg(result.image, maximumSize: thumbnailSize)
        }
        return receipt
    }

    /// The source file's own properties: the "Original Video" row of the
    /// metadata cards. A still source (DNG/JPEG) answers from ImageIO, a movie
    /// from its video track. Unreadable sources return nil rather than a guess.
    static func originalProperties(at url: URL) async -> RenderReceipt.Original? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
            return nil
        }
        var original = RenderReceipt.Original(fileSizeBytes: Int64(size))
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            original.codec = CGImageSourceGetType(source) as String?
            original.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            original.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            return original.codec != nil ? original : nil
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        if let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let upright = CGRect(origin: .zero, size: natural).applying(transform)
            if upright.width.isFinite, upright.height.isFinite,
               abs(upright.width) > 0, abs(upright.height) > 0 {
                original.pixelWidth = Int(abs(upright.width).rounded())
                original.pixelHeight = Int(abs(upright.height).rounded())
            }
        }
        if let fps = try? await track.load(.nominalFrameRate), fps.isFinite, fps > 0 {
            original.framesPerSecond = Double(fps)
        }
        if let description = try? await track.load(.formatDescriptions).first {
            let code = CMFormatDescriptionGetMediaSubType(description)
            let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                         UInt8((code >> 8) & 255), UInt8(code & 255)]
            original.codec = String(bytes: bytes, encoding: .ascii)
        }
        return original
    }

    /// The shared recipe a delivered still states in EXIF UserComment, keyed the
    /// way the movie path keys its QuickTime items.
    ///
    /// The payload JSON uses unprefixed keys (`film-stock`, `print-gauge`); the
    /// receipt republishes every allowed key as `com.filmemulation.<key>` so one
    /// queue view reads both media types. A missing, oversized, malformed or
    /// non-object payload yields no entries rather than partial guesses, and a
    /// value over the movie path's per-item bound is dropped on its own.
    static func stillMetadata(inImageProperties properties: [CFString: Any]) -> [String: String] {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              comment.utf8.count <= maximumPayloadBytes,
              let data = comment.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: String] else { return [:] }
        var values: [String: String] = [:]
        for (key, value) in payload {
            let namespaced = keyPrefix + key
            guard metadataKeys.contains(namespaced),
                  value.utf8.count <= maximumValueBytes else { continue }
            values[namespaced] = value
        }
        return values
    }

    /// Metadata read back from an already-delivered local file, for a receipt
    /// written before the image branch read the payload. Returns nil when the
    /// file has no allowed payload, so a legacy receipt is never given invented
    /// values. Reads only the app-owned output, never the Photos library.
    static func deliveredImageMetadata(at url: URL) -> [String: String]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let values = stillMetadata(inImageProperties: properties)
        return values.isEmpty ? nil : values
    }

    private static func jpeg(_ image: CGImage, maximumSize: Int) -> Data? {
        guard max(image.width, image.height) <= maximumSize else { return nil }
        let maximumBytes = maximumSize <= 320 ? 64 * 1024 : 1024 * 1024
        for quality in [0.75, 0.5, 0.3, 0.1] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= maximumBytes { return data as Data }
        }
        return nil
    }
}
