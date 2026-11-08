import Foundation
import Testing

struct StockCatalogTests {
    private struct Catalog: Decodable {
        let stocks: [FilmStockConfig]
    }

    /// Two negative/2383 stocks followed by Ektachrome positive reversal.
    @Test func shippedCatalogContainsTheThreeStocksInPickerOrder() throws {
        let root = TestRepository.root
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/stocks.json"))
        let stocks = try JSONDecoder().decode(Catalog.self, from: data).stocks

        #expect(stocks.map(\.stockId) == [
            "kodak5207", "kodak5219", "kodakektachrome100d"
        ])
        for stock in stocks {
            #expect(stock.category == .video)
            #expect(stock.lutName.hasSuffix(" - Apple Log 2.cube"))
            try stock.validate()
        }
        #expect(stocks.map(\.displayName) == ["250D / 5207", "500T / 5219", "Ektachrome 100D"])
        for stock in stocks {
            #expect(stock.stockDescription?.isEmpty == false)
        }
        let reversal = try #require(stocks.last)
        #expect(reversal.defaultISO == 100)
        #expect(reversal.colorTemperature == 5500)
        #expect(reversal.lightType == "D")
        #expect(reversal.primaryTint == "#0057D9")
        #expect(reversal.secondaryTint == "#FFD43B")
        #expect(reversal.effectiveRecipe.input.gamut == "Apple Wide Gamut")
        #expect(reversal.effectiveRecipe.output.transfer == "Gamma 2.4")
        #expect(!reversal.effectiveRecipe.colorContractVerified)
    }
}
