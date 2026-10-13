import Foundation
import Testing

@Suite("Render export settings")
struct RenderExportSettingsTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "RenderExportSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func missingPreferencesDefaultToRenderedOnlyAndHighQuality() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DeliverySettings.renderPreferences(defaults: defaults) == RenderDeliveryPreferences())
        #expect(RenderDeliveryPreferences().saveOriginalLog == false)
        #expect(RenderDeliveryPreferences().quality == .high)
        #expect(DeliverySettings.saveOriginalLogKey == "delivery.saveOriginalLog")
        #expect(DeliverySettings.renderQualityKey == "delivery.renderQuality")
    }

    @Test func storedPreferencesSurviveANewDefaultsInstance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DeliverySettings.saveOriginalLogKey)
        defaults.set("smaller", forKey: DeliverySettings.renderQualityKey)
        let restored = try #require(UserDefaults(suiteName: suite))

        #expect(DeliverySettings.renderPreferences(defaults: restored)
            == RenderDeliveryPreferences(saveOriginalLog: true, quality: .smaller))
    }

    @Test(arguments: ["unknown", "HIGH", "", "30_000_000"])
    func invalidStoredQualityFallsBackToHigh(rawValue: String) throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DeliverySettings.saveOriginalLogKey)
        defaults.set(rawValue, forKey: DeliverySettings.renderQualityKey)

        #expect(DeliverySettings.renderPreferences(defaults: defaults)
            == RenderDeliveryPreferences(saveOriginalLog: true, quality: .high))
    }

    @Test func mismatchedStoredQualityTypeFallsBackToHigh() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(30_000_000, forKey: DeliverySettings.renderQualityKey)

        #expect(DeliverySettings.renderPreferences(defaults: defaults).quality == .high)
    }

    @Test func qualitiesHaveFixedRenderBitratesAndStableIdentity() {
        #expect(RenderExportQuality.allCases == [.high, .smaller])
        #expect(RenderExportQuality.high.averageBitRate == 60_000_000)
        #expect(RenderExportQuality.smaller.averageBitRate == 30_000_000)
        #expect(RenderExportQuality.high.id == "high")
        #expect(RenderExportQuality.smaller.id == "smaller")
        #expect(RenderExportQuality.high.title == "High")
        #expect(RenderExportQuality.smaller.title == "Smaller")
    }

    @Test func renderPreferencesLeaveLegacyCaptureBitrateStoreUntouched() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let captureBitrateKey = "delivery.averageBitRate"
        defaults.set(47_000_000, forKey: captureBitrateKey)
        let existingCaptureBitrate = DeliverySettings.averageBitRate
        defaults.set(true, forKey: DeliverySettings.saveOriginalLogKey)
        defaults.set("smaller", forKey: DeliverySettings.renderQualityKey)

        #expect(DeliverySettings.renderPreferences(defaults: defaults).quality.averageBitRate == 30_000_000)
        #expect(defaults.integer(forKey: captureBitrateKey) == 47_000_000)
        #expect(DeliverySettings.averageBitRate == existingCaptureBitrate)
        #expect(DeliverySettings.defaultAverageBitRate == 60_000_000)
        #expect(DeliverySettings.aacAverageBitRate == 192_000)
        #expect(RenderEncodingContract.averageBitRate == 60_000_000)
    }

    @Test(arguments: RenderExportQuality.allCases)
    func preferencesRoundTripThroughCodable(quality: RenderExportQuality) throws {
        let preferences = RenderDeliveryPreferences(saveOriginalLog: true, quality: quality)
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(RenderDeliveryPreferences.self, from: data)

        #expect(restored == preferences)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["quality"] as? String == quality.rawValue)
        #expect(object["saveOriginalLog"] as? Bool == true)
    }

    @Test(arguments: ["{}", "{\"saveOriginalLog\":true}", "{\"quality\":\"smaller\"}"])
    func missingCodableKeysUseDefaults(json: String) throws {
        let restored = try JSONDecoder().decode(RenderDeliveryPreferences.self, from: Data(json.utf8))

        #expect(restored.saveOriginalLog == json.contains("true"))
        #expect(restored.quality == (json.contains("smaller") ? .smaller : .high))
    }

    @Test(arguments: [
        "{\"saveOriginalLog\":true,\"quality\":\"future-quality\"}",
        "{\"saveOriginalLog\":true,\"quality\":30000000}",
        "{\"saveOriginalLog\":true,\"quality\":null}"
    ])
    func unknownOrMismatchedCodableQualityFallsBackToHigh(json: String) throws {
        let restored = try JSONDecoder().decode(RenderDeliveryPreferences.self, from: Data(json.utf8))

        #expect(restored == RenderDeliveryPreferences(saveOriginalLog: true, quality: .high))
    }
}
