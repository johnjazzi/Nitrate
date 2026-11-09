import Foundation
import Observation
import os
import Testing

@Suite("Film stock preference persistence", .serialized)
@MainActor
struct FilmStockLibraryPersistenceTests {
    private var catalogURL: URL {
        TestRepository.root.appendingPathComponent("Resources/stocks.json")
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
        first.setSelectedStock("kodak5207")
        first.setISO(800, for: "kodak5207")
        first.setISO(3200, for: "kodak5219")

        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(restored.lastSelectedStockId == "kodak5207")
        let selected = try #require(restored.videoStocks().first { $0.stockId == restored.lastSelectedStockId })
        #expect(selected.stockId == "kodak5207")
        #expect(restored.lastISO(for: "kodak5207") == 800)
        #expect(restored.lastISO(for: "kodak5219") == 3200)
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

    @Test func perStockPrintGaugeSurvivesNewLibraryInstancesAndAppliesToConfig() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmStockLibrary(userDefaults: defaults)
        first.setGauge(.eightMillimetre, for: "kodak5207")
        first.setGauge(.seventyFiveMillimetre, for: "kodak5219")

        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(restored.lastGauge(for: "kodak5207") == .eightMillimetre)
        #expect(restored.lastGauge(for: "kodak5219") == .seventyFiveMillimetre)
        // A stock with no saved gauge falls back to the neutral 35mm reference.
        #expect(restored.lastGauge(for: "removed_stock_k2383") == nil)

        let config = try #require(restored.config(for: "kodak5207", iso: 250,
                                                  gauge: .eightMillimetre))
        #expect(config.effectivePrintGauge == .eightMillimetre)
        // The gauge must not disturb the per-shot ISO or the stock's own fields.
        #expect(config.defaultISO == 250)

        let neutral = try #require(restored.config(for: "kodak5207", iso: 250))
        #expect(neutral.effectivePrintGauge == .neutral)
    }

    @Test func renderJobCarriesTheGaugeAndStaysReadableWithoutIt() throws {
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                            stockId: "kodak5219", iso: 500,
                            printGauge: .sixteenMillimetre)
        let encoded = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RenderJob.self, from: encoded)
        #expect(decoded.printGauge == .sixteenMillimetre)
        #expect(decoded == job)

        // Legacy queue JSON written before the gauge existed carries no key.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "printGauge")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let legacyJob = try JSONDecoder().decode(RenderJob.self, from: legacy)
        #expect(legacyJob.printGauge == nil)
    }

    @Test func visibilityDefaultsOrderingPersistenceAndPreferences() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmStockLibrary(userDefaults: defaults)
        try library.load(from: catalogURL)
        let original = library.videoStocks()
        let first = try #require(original.first)
        #expect(original.count > 1)
        #expect(library.stocks.allSatisfy { library.isStockVisible($0.stockId) })
        library.setISO(800, for: first.stockId)
        library.setGauge(.eightMillimetre, for: first.stockId)
        let preference = PushPullPreference(isAutomatic: false, manualStops: .pushTwo)
        library.setPushPull(preference, for: first.stockId)
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/existing.mov"),
                            stockId: first.stockId, iso: 800, printGauge: .eightMillimetre)
        library.setStockVisible(false, for: first.stockId)
        #expect(library.videoStocks().map(\.stockId) == original.dropFirst().map(\.stockId))
        #expect(library.stocks.contains(first))
        #expect(library.preferredVisibleStock(for: first.stockId)?.stockId == original[1].stockId)
        #expect(library.preferredVisibleStock(for: original[1].stockId)?.stockId == original[1].stockId)
        let decoded = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
        #expect(library.config(for: decoded.stockId, iso: decoded.iso, gauge: decoded.printGauge) != nil)
        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(!restored.isStockVisible(first.stockId))
        restored.setStockVisible(true, for: first.stockId)
        #expect(restored.videoStocks().map(\.stockId) == original.map(\.stockId))
        #expect(restored.lastISO(for: first.stockId) == 800)
        #expect(restored.lastGauge(for: first.stockId) == .eightMillimetre)
        #expect(restored.lastPushPull(for: first.stockId) == preference)
    }

    @Test func lastVisibleGuardUnknownIDsAndAllHiddenRecovery() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmStockLibrary(userDefaults: defaults)
        try library.load(from: catalogURL)
        let original = library.videoStocks()
        let first = try #require(original.first)
        library.setStockVisible(false, for: "unknown-stock")
        #expect(!library.isStockVisible("unknown-stock"))
        #expect(library.videoStocks() == original)
        for stock in original.dropFirst() { library.setStockVisible(false, for: stock.stockId) }
        library.setStockVisible(false, for: first.stockId)
        #expect(library.videoStocks().map(\.stockId) == [first.stockId])
        defaults.set(original.map(\.stockId), forKey: "film_stock_hidden_ids")
        let repaired = FilmStockLibrary(userDefaults: defaults)
        try repaired.load(from: catalogURL)
        #expect(repaired.videoStocks().map(\.stockId) == [first.stockId])
        #expect(repaired.preferredVisibleStock(for: "unknown-stock")?.stockId == first.stockId)
        #expect(!(defaults.stringArray(forKey: "film_stock_hidden_ids") ?? []).contains(first.stockId))
    }

    @Test func futureStocksAreVisibleAndEmptyCatalogueHasNoSelection() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmStockLibrary(userDefaults: defaults)
        try library.load(from: catalogURL)
        let original = library.videoStocks()
        let template = try #require(original.first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object["stockId"] = "future-stock"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        defaults.set(original.map(\.stockId), forKey: "film_stock_hidden_ids")
        try JSONSerialization.data(withJSONObject: ["stocks": [object]]).write(to: url)
        let future = FilmStockLibrary(userDefaults: defaults)
        try future.load(from: url)
        #expect(future.isStockVisible("future-stock"))
        #expect(future.videoStocks().map(\.stockId) == ["future-stock"])
        try Data("{\"stocks\":[]}".utf8).write(to: url)
        try future.load(from: url)
        #expect(future.videoStocks().isEmpty)
        #expect(future.preferredVisibleStock(for: "future-stock") == nil)
    }

    @Test func visibilityChangesInvalidateObservation() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmStockLibrary(userDefaults: defaults)
        try library.load(from: catalogURL)
        let first = try #require(library.videoStocks().first)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = library.videoStocks()
        } onChange: {
            changed.withLock { $0 = true }
        }
        library.setStockVisible(false, for: first.stockId)
        #expect(changed.withLock { $0 })
    }
}
