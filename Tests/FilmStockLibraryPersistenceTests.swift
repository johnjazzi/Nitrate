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

    @Test func perStockPrintGaugeSurvivesNewLibraryInstancesAndAppliesToConfig() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmStockLibrary(userDefaults: defaults)
        first.setGauge(.eightMillimetre, for: "kodak250d_k2383")
        first.setGauge(.seventyFiveMillimetre, for: "kodak500t_k2383")

        let restored = FilmStockLibrary(userDefaults: defaults)
        try restored.load(from: catalogURL)
        #expect(restored.lastGauge(for: "kodak250d_k2383") == .eightMillimetre)
        #expect(restored.lastGauge(for: "kodak500t_k2383") == .seventyFiveMillimetre)
        // A stock with no saved gauge falls back to the neutral 35mm reference.
        #expect(restored.lastGauge(for: "cinestill50d_k2383") == nil)

        let config = try #require(restored.config(for: "kodak250d_k2383", iso: 250,
                                                  gauge: .eightMillimetre))
        #expect(config.effectivePrintGauge == .eightMillimetre)
        // The gauge must not disturb the per-shot ISO or the stock's own fields.
        #expect(config.defaultISO == 250)

        let neutral = try #require(restored.config(for: "kodak250d_k2383", iso: 250))
        #expect(neutral.effectivePrintGauge == .neutral)
    }

    @Test func renderJobCarriesTheGaugeAndStaysReadableWithoutIt() throws {
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                            stockId: "kodak500t_k2383", iso: 500,
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
}
