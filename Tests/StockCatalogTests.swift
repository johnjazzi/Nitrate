import Foundation
import Testing

struct StockCatalogTests {
    private struct Catalog: Decodable {
        let stocks: [FilmStockConfig]
    }

    @Test func shippedCatalogContainsOnlyK2383VideoStocksInPickerOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/stocks.json"))
        let stocks = try JSONDecoder().decode(Catalog.self, from: data).stocks

        #expect(stocks.map(\.stockId) == [
            "cinestill50d_k2383", "kodak250d_k2383", "kodak200t_k2383", "kodak500t_k2383"
        ])
        for stock in stocks {
            #expect(stock.category == .video)
            #expect(stock.lutName.contains("K2383"))
            try stock.validate()
        }
        #expect(stocks[0].displayName == "50D K2383")
    }
}
