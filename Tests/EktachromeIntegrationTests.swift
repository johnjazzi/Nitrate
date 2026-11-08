import CoreImage
import Foundation
import Testing

@Suite(.serialized)
struct EktachromeIntegrationTests {
    private final class BundleToken {}
    private struct Catalog: Decodable { let stocks: [FilmStockConfig] }

    private func stocks() throws -> [FilmStockConfig] {
        let data = try Data(contentsOf: TestRepository.url(for: "App/Resources/stocks.json"))
        return try JSONDecoder().decode(Catalog.self, from: data).stocks
    }

    /// Exercise the real delivery entry point, not just StillFilmRenderResources.
    /// An absent RAW must reach RAW decoding for every selectable stock. This
    /// proves admission, not a successful RAW decode or completed photo delivery.
    @Test func everyShippingStockReachesTheRAWDecoderThroughTheProductionEntry() throws {
        let missing = TestRepository.artifactDirectory("stock-admission")
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
        for stock in try stocks() {
            do {
                _ = try DevelopmentPhotoRenderer.render(originalDNG: missing, stockID: stock.stockId,
                    bundle: Bundle(for: BundleToken.self))
                Issue.record("A nonexistent RAW must not render")
            } catch is RAWPhotoDecoder.DecodeError {
                // Correct boundary: stock admitted, missing input refused.
            } catch {
                Issue.record("\(stock.stockId) failed before RAW decoding: \(error)")
            }
        }
    }

    @Test func everyShippingStockDevelopsANonuniformLinearImageThroughTheGPU() throws {
        let side = 64
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var values = [Float](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                values[offset] = 0.005 + 1.2 * Float(x) / Float(side - 1)
                values[offset + 1] = 0.005 + 0.8 * Float(y) / Float(side - 1)
                values[offset + 2] = 0.01 + 0.4 * Float(x + y) / Float(2 * side - 2)
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        let input = CIImage(bitmapData: data, bytesPerRow: side * 16,
                            size: extent.size, format: .RGBAf, colorSpace: space)
        var outputs: [[Float]] = []
        for stock in try stocks() {
            let film = try StillFilmRenderResources(stockID: stock.stockId, gauge: .neutral,
                seed: 42, bundle: Bundle(for: BundleToken.self))
            #expect(film.config.colorTemperature == stock.colorTemperature)
            let developed = try DevelopmentPhotoRenderer.develop(linearImage: input, film: film)
            var output = [Float](repeating: 0, count: side * side * 4)
            film.context.render(developed, toBitmap: &output, rowBytes: side * 16,
                bounds: extent, format: .RGBAf, colorSpace: space)
            let rgb = output.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
            let finite = rgb.allSatisfy { $0.isFinite }
            #expect(finite)
            #expect((rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.4,
                    "\(stock.stockId) must retain spatial range")
            outputs.append(output)
        }
        #expect(outputs.count == 3)
        #expect(outputs[2] != outputs[0] && outputs[2] != outputs[1],
                "The new stock must produce its own result, not fall back to a negative")
    }
}
