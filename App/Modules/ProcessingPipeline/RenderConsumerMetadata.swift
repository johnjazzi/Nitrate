import AVFoundation
import CoreGraphics
import Foundation

/// Orientation of the delivered frame: the encoded size with the track's
/// preferred transform applied — i.e. what Photos actually shows.
enum RenderDeliveryOrientation: String, Equatable, Sendable {
    case portrait
    case landscape

    /// Nil for a square frame: the keyword set names no orientation rather than
    /// inventing one.
    static func from(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> RenderDeliveryOrientation? {
        let delivered = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(delivered.width)
        let height = abs(delivered.height)
        if width > height { return .landscape }
        if height > width { return .portrait }
        return nil
    }
}

/// The short consumer-facing tag Photos and Finder show for a Nitrate movie:
/// `nitrate: <stock name> | <gauge>`, plus `nitrate` and the captured
/// orientation as keywords. The detailed recipe stays in the
/// `com.filmemulation.*` keys, which consumer apps do not display.
enum RenderConsumerMetadata {
    static let keyword = "nitrate"
    static let captionPrefix = "nitrate: "

    struct Tag: Equatable, Sendable {
        let caption: String
        let keywords: [String]
    }

    static func caption(stockName: String, gauge: String) -> String {
        "\(captionPrefix)\(stockName) | \(gauge)"
    }

    static func keywords(orientation: RenderDeliveryOrientation?) -> [String] {
        guard let orientation else { return [keyword] }
        return [keyword, orientation.rawValue]
    }

    /// Embedded keyword list, as consumer apps read it back.
    static func keywordsValue(orientation: RenderDeliveryOrientation?) -> String {
        keywords(orientation: orientation).joined(separator: ", ")
    }

    /// Reads the tag back out of a delivered movie, so the Photos delivery path
    /// uses the file's own contents as the source of truth. Reads only the
    /// movie's metadata and video track — never the Photos library.
    static func tag(for url: URL) async -> Tag? {
        let asset = AVURLAsset(url: url)
        guard let stockName = try? await stringValue(for: "com.filmemulation.stock-name", in: asset),
              !stockName.isEmpty else { return nil }
        let gauge = (try? await stringValue(for: "com.filmemulation.print-gauge", in: asset))
            ?? PrintGauge.neutral.rawValue
        var orientation: RenderDeliveryOrientation?
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                orientation = RenderDeliveryOrientation.from(naturalSize: size, preferredTransform: transform)
            }
        }
        return Tag(caption: caption(stockName: stockName, gauge: gauge),
                   keywords: keywords(orientation: orientation))
    }

    private static func stringValue(for key: String, in asset: AVURLAsset) async throws -> String? {
        for item in try await asset.load(.metadata) where (item.key as? String) == key {
            return try await item.load(.stringValue)
        }
        return nil
    }
}
