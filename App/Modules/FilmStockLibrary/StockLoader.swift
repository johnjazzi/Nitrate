import Foundation

/// AD-10 + AD-12: Loads film stock configurations from stocks.json bundled resource.
/// Single source of truth for stock metadata.
@MainActor
final class FilmStockLibrary {
    private(set) var stocks: [FilmStockConfig] = []
    private let isoDefaultsKey = "film_stock_iso_defaults"

    /// Load stocks from bundled stocks.json.
    func load() throws {
        guard let url = Bundle.main.url(forResource: "stocks", withExtension: "json") else {
            throw StockError.missingResource("stocks.json not found in bundle.")
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let container = try decoder.decode(StocksContainer.self, from: data)
        stocks = container.stocks
    }

    /// AD-10: Single factory method — callers never construct FilmStockConfig directly.
    func config(for stockId: String, iso: Float) -> FilmStockConfig? {
        guard var template = stocks.first(where: { $0.stockId == stockId }) else {
            return nil
        }
        return FilmStockConfig(
            stockId: template.stockId,
            displayName: template.displayName,
            category: template.category,
            lutName: template.lutName,
            halationStrength: template.halationStrength,
            glowStrength: template.glowStrength,
            defaultISO: iso
        )
    }

    /// Returns v1 video stocks only (Kodak 250D and 500T).
    func videoStocks() -> [FilmStockConfig] {
        stocks.filter { $0.category == .video }
    }

    /// Persist the last-used ISO per stock across sessions.
    /// Spec: "Each shot remembers its own ISO. App restores last-used ISO per stock."
    func saveLastISO(for stockId: String, iso: Float) {
        var defaults = UserDefaults.standard.dictionary(forKey: isoDefaultsKey) as? [String: Float] ?? [:]
        defaults[stockId] = iso
        UserDefaults.standard.set(defaults, forKey: isoDefaultsKey)
    }

    /// Restore the last-used ISO for a stock, or fall back to the stock's default.
    func lastISO(for stockId: String) -> Float {
        let defaults = UserDefaults.standard.dictionary(forKey: isoDefaultsKey) as? [String: Float] ?? [:]
        return defaults[stockId] ?? stocks.first(where: { $0.stockId == stockId })?.defaultISO ?? 400
    }
}

// MARK: - Codable helpers

private struct StocksContainer: Codable {
    let stocks: [FilmStockConfig]
}

enum StockError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let message):
            return message
        }
    }
}