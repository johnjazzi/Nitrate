import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct SplashEdgeOverlayTests {
    @MainActor
    @Test(arguments: [320, 375, 430])
    func rendersBoundedLabelsAtPhoneWidths(width: Int) throws {
        let height = 640
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplashEdgeOverlayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for useLongLabels in [false, true] {
            var details = SplashEdgeDetails.placeholder
            if useLongLabels {
                details.stock = "KODAK VISION3 500T COLOR NEGATIVE FILM / 5219 · EI 500"
            }
            let version = useLongLabels
                ? "NITRATE VERSION 2026.10.15 · BUILD 123456789 · DEVELOPMENT PREVIEW"
                : "0.1.0 (1)"
            let renderer = ImageRenderer(content: SplashEdgeOverlay(details: details, version: version)
                .frame(width: CGFloat(width), height: CGFloat(height)))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == width)
            #expect(image.height == height)

            let pixels = try rgbaPixels(image)
            let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }
            #expect(visible.count > 100, "The native render must contain visible edge labels.")
            // Test actual glyph ink, not just the outer fixed-size view. Leave two
            // points for antialiasing around the overlay's authored edge insets.
            let columns = visible.map { ($0 / 4) % width }
            let rows = visible.map { ($0 / 4) / width }
            let minColumn = try #require(columns.min())
            let maxColumn = try #require(columns.max())
            let minRow = try #require(rows.min())
            let maxRow = try #require(rows.max())
            #expect(minColumn >= 20)
            #expect(maxColumn < width - 20)
            #expect(minRow >= 8)
            #expect(maxRow < height - 8)

            // Count separated ink bands at the edges, away from the vertical
            // codes. Taking either edge avoids depending on bitmap row order.
            // The old shared baseline has only one band; long stock must also
            // separate from the marking rather than truncate beside it.
            let edgeBands = max(
                bandCount(rows.filter { $0 < 160 }),
                bandCount(rows.filter { $0 >= height - 160 })
            )
            #expect(edgeBands >= (useLongLabels ? 3 : 2))

            let suffix = useLongLabels ? "long" : "default"
            let url = directory.appendingPathComponent("splash-\(width)-\(suffix).png")
            let destination = try #require(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            print("Splash layout render: \(url.path)")
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(
                x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)
            ))
        }
        return pixels
    }

    private func bandCount(_ rows: [Int]) -> Int {
        let occupied = Set(rows).sorted()
        guard let first = occupied.first else { return 0 }
        var count = 1
        var previous = first
        for row in occupied.dropFirst() {
            if row - previous > 3 { count += 1 }
            previous = row
        }
        return count
    }
}
