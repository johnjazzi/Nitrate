import Foundation
import Observation

/// AD-10 + AD-12: Loads film stock configurations from stocks.json bundled resource.
/// Single source of truth for stock metadata.
@MainActor
@Observable
final class FilmStockLibrary {
    private(set) var stocks: [FilmStockConfig] = []
    private var hiddenStockIDs: Set<String>
    private let hiddenStockIDsKey = "film_stock_hidden_ids"
    private let isoDefaultsKey = "film_stock_iso_defaults"
    private let gaugeDefaultsKey = "film_stock_gauge_defaults"
    private let pushPullDefaultsKey = "film_stock_push_pull_defaults"
    private let selectedStockKey = "film_stock_selected_id"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        hiddenStockIDs = Set(userDefaults.stringArray(forKey: "film_stock_hidden_ids") ?? [])
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
        // Repair legacy/corrupt preferences without inventing a stock for an empty catalogue.
        if videoStocks().isEmpty, let first = stocks.first(where: { $0.category == .video }) {
            hiddenStockIDs.remove(first.stockId)
            persistVisibility()
        }
    }

    /// AD-10: Return a config with all fields preserved (including tints).
    func config(for stockId: String, iso: Float, gauge: PrintGauge? = nil,
                pushPull: PushPullExposure = .neutral) -> FilmStockConfig? {
        guard let template = stocks.first(where: { $0.stockId == stockId }) else {
            return nil
        }
        return template.overridingISO(iso).overridingGauge(gauge).overridingPushPull(pushPull)
    }

    /// Returns stocks available for video rendering.
    func videoStocks() -> [FilmStockConfig] {
        stocks.filter { $0.category == .video && isStockVisible($0.stockId) }
    }

    func isStockVisible(_ stockID: String) -> Bool {
        stocks.contains { $0.stockId == stockID } && !hiddenStockIDs.contains(stockID)
    }

    func setStockVisible(_ visible: Bool, for stockID: String) {
        guard let stock = stocks.first(where: { $0.stockId == stockID }) else { return }
        if visible {
            hiddenStockIDs.remove(stockID)
        } else {
            guard stock.category != .video || !isStockVisible(stockID) || videoStocks().count > 1 else { return }
            hiddenStockIDs.insert(stockID)
        }
        persistVisibility()
    }

    /// Resolve a picker selection, never a queued job's render configuration.
    func preferredVisibleStock(for stockID: String?) -> FilmStockConfig? {
        let visible = videoStocks()
        return visible.first(where: { $0.stockId == stockID }) ?? visible.first
    }

    private func persistVisibility() {
        userDefaults.set(hiddenStockIDs.sorted(), forKey: hiddenStockIDsKey)
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

    /// Save the last-used print gauge for a stock (nil = neutral 35mm).
    func setGauge(_ gauge: PrintGauge?, for stockId: String) {
        var defaults = gaugeValues()
        if let gauge { defaults[stockId] = gauge.rawValue } else { defaults.removeValue(forKey: stockId) }
        userDefaults.set(defaults, forKey: gaugeDefaultsKey)
    }

    /// Restore the last-used print gauge for a stock; nil means neutral 35mm.
    func lastGauge(for stockId: String) -> PrintGauge? {
        gaugeValues()[stockId].flatMap(PrintGauge.init(rawValue:))
    }

    /// Save the sheet's push/pull preference (auto checked, or a manual rung).
    func setPushPull(_ preference: PushPullPreference, for stockId: String) {
        var defaults = pushPullValues()
        defaults[stockId] = preference.encoded
        userDefaults.set(defaults, forKey: pushPullDefaultsKey)
    }

    /// Restore the last-used push/pull preference for a stock.
    func lastPushPull(for stockId: String) -> PushPullPreference {
        PushPullPreference.decode(pushPullValues()[stockId])
    }

    private func pushPullValues() -> [String: String] {
        (userDefaults.dictionary(forKey: pushPullDefaultsKey) ?? [:]).reduce(into: [:]) { values, item in
            if let text = item.value as? String { values[item.key] = text }
        }
    }

    private func gaugeValues() -> [String: String] {
        (userDefaults.dictionary(forKey: gaugeDefaultsKey) ?? [:]).reduce(into: [:]) { values, item in
            if let text = item.value as? String { values[item.key] = text }
        }
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
