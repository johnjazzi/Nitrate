import Foundation

/// AD-10 + AD-12: Loads film stock configurations from stocks.json bundled resource.
/// Single source of truth for stock metadata.
@MainActor
final class FilmStockLibrary {
    private(set) var stocks: [FilmStockConfig] = []
    private let isoDefaultsKey = "film_stock_iso_defaults"
    private let selectedStockKey = "film_stock_selected_id"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Persisted last-selected stock ID.
    var lastSelectedStockId: String? {
        userDefaults.string(forKey: selectedStockKey)
    }

    /// Persist the active stock selection.
    func setSelectedStock(_ stockId: String) {
        userDefaults.set(stockId, forKey: selectedStockKey)
    }

    /// Load stocks from bundled stocks.json.
    func load(from resourceURL: URL? = nil) throws {
        guard let url = resourceURL ?? Bundle.main.url(forResource: "stocks", withExtension: "json") else {
            throw StockError.missingResource("stocks.json not found in bundle.")
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let container = try decoder.decode(StocksContainer.self, from: data)
        try container.stocks.forEach { try $0.validate() }
        stocks = container.stocks
    }

    /// AD-10: Return a config with all fields preserved (including tints).
    func config(for stockId: String, iso: Float) -> FilmStockConfig? {
        guard let template = stocks.first(where: { $0.stockId == stockId }) else {
            return nil
        }
        return template.overridingISO(iso)
    }

    /// Returns stocks available for video rendering.
    func videoStocks() -> [FilmStockConfig] {
        stocks.filter { $0.category == .video }
    }

    /// Save the last-used ISO for a stock.
    func setISO(_ iso: Float, for stockId: String) {
        saveLastISO(for: stockId, iso: iso)
    }

    /// Persist the last-used ISO per stock across sessions.
    func saveLastISO(for stockId: String, iso: Float) {
        var defaults = isoValues()
        defaults[stockId] = iso
        userDefaults.set(defaults, forKey: isoDefaultsKey)
    }

    /// Restore the last-used ISO for a stock, or fall back to the stock's default.
    func lastISO(for stockId: String) -> Float {
        let defaults = isoValues()
        return defaults[stockId] ?? stocks.first(where: { $0.stockId == stockId })?.defaultISO ?? 400
    }

    private func isoValues() -> [String: Float] {
        (userDefaults.dictionary(forKey: isoDefaultsKey) ?? [:]).reduce(into: [:]) { values, item in
            if let number = item.value as? NSNumber { values[item.key] = number.floatValue }
        }
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
        case .missingResource(let msg): return msg
        }
    }
}
