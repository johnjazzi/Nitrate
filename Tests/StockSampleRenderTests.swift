import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

struct StockSampleRenderTests {
    private final class BundleToken {}

    @Test func sampleCatalogIsBundledWithAPreviewForEveryShippingStock() throws {
        let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
        #expect(catalog.scenes.count == 3)
        let data = try Data(contentsOf: TestRepository.url(for: "App/Resources/stocks.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stocks = try #require(object["stocks"] as? [[String: Any]])
        for stock in stocks {
            let stockID = try #require(stock["stockId"] as? String)
            for scene in catalog.scenes {
                let url = try #require(scene.imageURL(stockID: stockID, directory: catalog.directory))
                #expect(StockSamplePhoto.load(url) != nil)
            }
        }
    }

    @MainActor @Test func realPhotoFacesAreNonblankAtNarrowAndWidePhoneWidths() throws {
        let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
        for scene in catalog.scenes {
            for stockID in scene.previews.keys.sorted() {
                let url = try #require(scene.imageURL(stockID: stockID, directory: catalog.directory))
                let photo = try #require(StockSamplePhoto.load(url))
                for width: CGFloat in [288, 398] {
                    let content = StockSamplePhoto(image: photo, title: scene.title, stockName: stockID)
                        .frame(width: width, height: 310)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage)
                    #expect(image.width == Int(width * 2))
                    #expect(image.height == 620)
                    let pixels = try rgba(image)
                    // Evaluate the photo, excluding the caption's bottom material.
                    var values: [UInt8] = []
                    var opaque = true
                    var whiteSamples = 0
                    var midtoneSamples = 0
                    var sampleCount = 0
                    for row in stride(from: 40, to: 400, by: 8) {
                        for column in stride(from: 40, to: image.width - 40, by: 8) {
                            let index = (row * image.width + column) * 4
                            opaque = opaque && pixels[index + 3] > 240
                            let red = Int(pixels[index])
                            let green = Int(pixels[index + 1])
                            let blue = Int(pixels[index + 2])
                            let brightness = (red + green + blue) / 3
                            if min(red, green, blue) > 247 { whiteSamples += 1 }
                            if (20...239).contains(brightness) { midtoneSamples += 1 }
                            sampleCount += 1
                            values.append(contentsOf: pixels[index..<(index + 3)])
                        }
                    }
                    #expect(opaque)
                    #expect(Double(whiteSamples) / Double(sampleCount) < 0.45,
                            "A nearly white sample is not a useful stock preview.")
                    #expect(Double(midtoneSamples) / Double(sampleCount) > 0.25,
                            "The photo must retain recognizable midtone content.")
                    #expect(Int(values.max() ?? 0) - Int(values.min() ?? 0) > 80,
                            "An example must contain photographic detail, not a blank placeholder.")
                    #expect(pixels[3] < 20, "Rounded corners should remain transparent.")
                    try save(image, name: "\(scene.id)-\(stockID)-\(Int(width))")
                }
            }
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                               bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func save(_ image: CGImage, name: String) throws {
        let directory = TestRepository.artifactDirectory("stock-selector")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                      UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
