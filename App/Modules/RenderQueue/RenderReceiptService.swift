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
        "source-color-validation", "capture-color-space", "source-color-test-bypass"
    ].map { "com.filmemulation." + $0 })

    static func capture(url: URL, renderDurationSeconds: Double?,
                        includeThumbnail: Bool = true) async -> RenderReceipt {
        var receipt = RenderReceipt(renderDurationSeconds: renderDurationSeconds)
        receipt.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        receipt.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        receipt.fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
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
                      let value = try? await item.load(.stringValue), value.utf8.count <= 16_384 else { continue }
                receipt.metadata[key] = value
            }
        }
        guard includeThumbnail else { return receipt }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        if let result = try? await generator.image(at: .zero) {
            receipt.thumbnailJPEG = jpeg(result.image)
        }
        return receipt
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        guard max(image.width, image.height) <= 320 else { return nil }
        for quality in [0.75, 0.5, 0.3, 0.1] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= 64 * 1024 { return data as Data }
        }
        return nil
    }
}
