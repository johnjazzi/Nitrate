import Foundation
import Testing

@Suite("Film stock preference persistence", .serialized)
@MainActor
struct FilmStockLibraryPersistenceTests {
    private var catalogURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/stocks.json")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "FilmStockLibraryPersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileReadUnknown)
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func stockAndPerStockIsoSurviveNewLibraryInstances() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmStockLibrary(userDefaults: defaults)
        first.setSelectedStock("kodak250d_k2383")
        first.setISO(800, for: "kodak250d_k2383")
        first.setISO(3200, for: "kodak500t_k2383")

        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(restored.lastSelectedStockId == "kodak250d_k2383")
        let selected = try #require(restored.videoStocks().first { $0.stockId == restored.lastSelectedStockId })
        #expect(selected.stockId == "kodak250d_k2383")
        #expect(restored.lastISO(for: "kodak250d_k2383") == 800)
        #expect(restored.lastISO(for: "kodak500t_k2383") == 3200)
    }

    @Test func unknownPersistedStockIDRemainsAOptionalSelection() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmStockLibrary(userDefaults: defaults)
        first.setSelectedStock("removed-stock")

        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(restored.lastSelectedStockId == "removed-stock")
        #expect(restored.videoStocks().first { $0.stockId == restored.lastSelectedStockId } == nil)
        #expect(restored.config(for: "removed-stock", iso: 400) == nil)
        #expect(restored.lastISO(for: "removed-stock") == 400)
    }
}
