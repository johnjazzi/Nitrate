import Foundation
import Testing

struct StockCatalogTests {
    private struct Catalog: Decodable {
        let stocks: [FilmStockConfig]
    }

    /// The catalogue ships exactly these two stocks, in picker order, and nothing
    /// else. The fixed Kodak Vision 2383 print stage is not declared here: it is
    /// baked into the cubes (see docs/lut-provenance.md), so the identifiers and
    /// LUT names carry the negative emulsion only.
    @Test func shippedCatalogContainsExactlyTheTwoVideoStocksInPickerOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/stocks.json"))
        let stocks = try JSONDecoder().decode(Catalog.self, from: data).stocks

        #expect(stocks.map(\.stockId) == [
            "kodak5207", "kodak5219"
        ])
        for stock in stocks {
            #expect(stock.category == .video)
            #expect(stock.lutName.hasSuffix(" - Apple Log 2.cube"))
            try stock.validate()
        }
        #expect(stocks.map(\.displayName) == ["250D / 5207", "500T / 5219"])
    }
}
