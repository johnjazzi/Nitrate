import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Contracts for the shipped plates and the inputs the live LUT preview needs.
///
/// The rendered look is not asserted here: the GPU applies the cube at display time, so
/// these tests pin what can be checked offscreen — that every scene ships a plate, that the
/// plate is a real image at the shipped size, and that the cube the preview will load parses.
struct StockSampleRenderTests {
    private final class BundleToken {}

    @Test func everySceneShipsAPlateAtTheBudgetedSize() throws {
        let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
        #expect(catalog.scenes.count == 8)
        let data = try Data(contentsOf: TestRepository.url(for: "App/Resources/stocks.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stocks = try #require(object["stocks"] as? [[String: Any]])
        #expect(stocks.count == 2, "the selector must preview every shipping stock")
        for scene in catalog.scenes {
            let url = scene.plateURL(directory: catalog.directory)
            let image = try #require(PlateImage.load(url), "\(scene.id) has no decodable plate")
            #expect(image.width == 480 && image.height == 720,
                    "\(scene.id): plates ship at the budgeted 2:3 size")
        }
    }

    @Test func everyStockCubeParsesForTheLivePreview() throws {
        for stock in ["5207 - Apple Log 2.cube", "5219 - Apple Log 2.cube"] {
            let url = try #require(Bundle(for: BundleToken.self)
                .url(forResource: stock, withExtension: nil)
                ?? Bundle(for: BundleToken.self).url(forResource: stock, withExtension: nil, subdirectory: "LUTs"))
            let cube = try PlateCube.parse(String(contentsOf: url, encoding: .utf8))
            #expect(cube.size >= 17)
        }
    }

    @MainActor @Test func platesAreNonblankPhotographs() throws {
        let catalog = try StockSampleCatalog.load(bundle: Bundle(for: BundleToken.self))
        for scene in catalog.scenes {
            let url = scene.plateURL(directory: catalog.directory)
            let image = try #require(PlateImage.load(url))
            let pixels = try rgba(image)
            var values: [UInt8] = []
            var midtoneSamples = 0
            var sampleCount = 0
            for row in stride(from: 0, to: image.height, by: 12) {
                for column in stride(from: 0, to: image.width, by: 12) {
                    let index = (row * image.width + column) * 4
                    let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                    let brightness = (red + green + blue) / 3
                    if (20...239).contains(brightness) { midtoneSamples += 1 }
                    sampleCount += 1
                    values.append(contentsOf: pixels[index..<(index + 3)])
                }
            }
            #expect(Double(midtoneSamples) / Double(sampleCount) > 0.25,
                    "\(scene.id): a plate that is mostly clipped shows no roll character")
            #expect(Int(values.max() ?? 0) - Int(values.min() ?? 0) > 60,
                    "\(scene.id): plate looks blank")
            try save(image, name: scene.id)
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
        let directory = TestRepository.artifactDirectory("stock-plates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                      UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
