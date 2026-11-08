import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import Testing

struct StockInfoTests {
    private func stock(_ id: String = "sample", temperature: Float = 5600) -> FilmStockConfig {
        FilmStockConfig(stockId: id, displayName: "Sample Stock", category: .video,
                        lutName: "sample.cube", halationStrength: 0, glowStrength: 0,
                        grainSize: 1, colorTemperature: temperature, defaultISO: 100,
                        primaryTint: "#E8C46C", secondaryTint: "#665224")
    }

    @Test func historicalPayloadWithoutDescriptionAndExplicitNullDecode() throws {
        let original = stock()
        #expect(original.stockDescription == nil)
        let encoded = try JSONEncoder().encode(original)
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document.removeValue(forKey: "stockDescription")
        let missing = try JSONDecoder().decode(FilmStockConfig.self,
                                               from: JSONSerialization.data(withJSONObject: document))
        #expect(missing == original)
        document["stockDescription"] = NSNull()
        let null = try JSONDecoder().decode(FilmStockConfig.self,
                                            from: JSONSerialization.data(withJSONObject: document))
        #expect(null == original)
    }

    @Test func descriptionRoundTripsAndSurvivesEveryOverride() throws {
        var authored = stock()
        authored.stockDescription = "Catalogue-authored stock information."
        let restored = try JSONDecoder().decode(FilmStockConfig.self, from: JSONEncoder().encode(authored))
        #expect(restored == authored)
        for copy in [authored.overridingISO(200), authored.overridingGauge(.sixteenMillimetre),
                     authored.overridingDiffusion(nil), authored.overridingPushPull(.neutral)] {
            #expect(copy.stockDescription == authored.stockDescription)
        }
        #expect(authored.defaultISO == 100)
    }

    @Test func fallbackUsesOnlyConfiguredFactsAndBlankCopyFallsBack() {
        var daylight = stock()
        #expect(daylight.stockInfoMetadata == "ISO 100 · Daylight")
        #expect(daylight.stockInfoDescription == "Sample Stock is configured for ISO 100 with daylight white balance.")
        daylight.stockDescription = " \n "
        #expect(daylight.stockInfoDescription == stock().stockInfoDescription)
        daylight.stockDescription = " Authored description. \n"
        #expect(daylight.stockInfoDescription == "Authored description.")
        let tungsten = stock(temperature: 3200)
        #expect(tungsten.stockInfoMetadata == "ISO 100 · Tungsten")
        #expect(tungsten.stockInfoDescription == "Sample Stock is configured for ISO 100 with tungsten white balance.")
    }

    @Test func infoDismissesAndReopensTheSameUnselectedStockWithFreshFeedback() {
        let selected = stock("selected").overridingGauge(.eightMillimetre)
        let unselected = stock("unselected")
        let catalogue = [selected, unselected]
        let originalCenter = StockCarouselSelection.centeredId(onOpen: selected.stockId, stocks: catalogue)
        var info = StockInfoPresentation()
        #expect(info.stock == nil)
        info.present(unselected)
        #expect(info.stock == unselected)
        #expect(info.feedbackTrigger == 1)
        info.dismiss()
        #expect(info.stock == nil)
        info.present(unselected)
        #expect(info.stock == unselected)
        #expect(info.feedbackTrigger == 2)
        info.present(selected)
        #expect(info.stock == selected)
        #expect(info.feedbackTrigger == 3)
        // Info state does not own or receive selection/scroll/gauge bindings.
        // Gesture exclusivity and physical haptics still require device acceptance.
        #expect(StockCarouselSelection.centeredId(onOpen: selected.stockId, stocks: catalogue) == originalCenter)
        #expect(selected.effectivePrintGauge == .eightMillimetre)
        #expect(StockCarouselSelection.gauge(onSelecting: selected.stockId,
                                           from: selected.stockId, remembered: .eightMillimetre) == nil)
    }

    @MainActor @Test func productionCardAndInfoContentHaveNonblankBoundedRenders() throws {
        var authored = stock()
        authored.stockDescription = "A catalogue-authored description with enough detail to wrap across several lines."
        for width: CGFloat in [272, 350] {
            let content = StockInfoContent(stock: authored)
                .padding(24).frame(width: width).background(Color.black).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(width))
            #expect(image.height > 120 && image.height < 420)
            #expect(try brightPixels(image) > 300, "Production text must render visible ink, not an empty sheet.")
        }
        let card = ImageRenderer(content: StockCarouselCard(stock: authored, isSelected: true)
            .frame(width: 160, height: 132).background(Color.black).environment(\.colorScheme, .dark))
        card.scale = 1
        let image = try #require(card.cgImage)
        #expect(image.width == 160 && image.height == 132)
        #expect(try brightPixels(image) > 200)
    }

    @MainActor @Test func everyShippingStockRendersReadableInfoAndItsActualCard() throws {
        struct Catalog: Decodable { let stocks: [FilmStockConfig] }
        let data = try Data(contentsOf: TestRepository.url(for: "App/Resources/stocks.json"))
        let stocks = try JSONDecoder().decode(Catalog.self, from: data).stocks
        let directory = TestRepository.artifactDirectory("stock-info")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stock in stocks {
            let views: [(String, AnyView)] = [
                ("info", AnyView(StockInfoContent(stock: stock).padding(24).frame(width: 320)
                    .background(Color.black).environment(\.colorScheme, .dark))),
                ("card", AnyView(StockCarouselCard(stock: stock, isSelected: true)
                    .frame(width: 160, height: 132).background(Color.black).environment(\.colorScheme, .dark)))
            ]
            for (name, view) in views {
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                if name == "info" {
                    #expect(image.height > 200 && image.height < 900)
                    #expect(try brightPixels(image) > 600)
                }
                let path = directory.appendingPathComponent("\(stock.stockId)-\(name).png")
                let writer = try #require(CGImageDestinationCreateWithURL(path as CFURL,
                    UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(writer, image, nil)
                #expect(CGImageDestinationFinalize(writer))
            }
        }
    }

    private func brightPixels(_ image: CGImage) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                               bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 180 && bytes[$0 + 1] > 150 && bytes[$0 + 2] > 80 && bytes[$0 + 3] > 200
        }.count
    }
}
