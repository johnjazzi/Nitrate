import Foundation
import SwiftUI
import Testing

/// The two persisted camera appearance preferences: the control accent and the
/// lens control placement.
///
/// These cover the pure resolution rules — defaults, unknown-value fallbacks,
/// stock-metadata accent resolution and isolated `UserDefaults` persistence. They
/// are not a rendered-layout or device pass.
struct CameraControlAppearanceTests {
    private func store(_ name: String) throws -> UserDefaults {
        let suite = "CameraControlAppearanceTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Keys and defaults

    @Test func preferenceKeysAreStable() {
        #expect(CameraControlColorPreference.preferenceKey == "camera.controlColor")
        #expect(CameraLensControlPosition.preferenceKey == "camera.lensControlPosition")
    }

    @Test func controlColorDefaultsToFollowStock() {
        #expect(CameraControlColorPreference.defaultValue == .followStock)
        #expect(CameraControlColorPreference.resolved("followStock") == .followStock)
        #expect(CameraControlColorPreference.resolved("orange") == .orange)
        #expect(CameraControlColorPreference.resolved("green") == .green)
        // Absent, empty and unrecognised persisted values fall back to Follow stock.
        #expect(CameraControlColorPreference.resolved("") == .followStock)
        #expect(CameraControlColorPreference.resolved("chartreuse") == .followStock)
        #expect(CameraControlColorPreference.resolved("FOLLOWSTOCK") == .followStock)
        #expect(CameraControlColorPreference.allCases == [.followStock, .orange, .green])
    }

    @Test func lensPlacementDefaultsToTopRight() {
        #expect(CameraLensControlPosition.defaultValue == .topRight)
        #expect(CameraLensControlPosition.resolved("topRight") == .topRight)
        #expect(CameraLensControlPosition.resolved("aboveShutter") == .aboveShutter)
        #expect(CameraLensControlPosition.resolved("") == .topRight)
        #expect(CameraLensControlPosition.resolved("leftEdge") == .topRight)
        #expect(CameraLensControlPosition.allCases == [.topRight, .aboveShutter])
    }

    @Test func choicesCarryTheirSettingsTitles() {
        #expect(CameraControlColorPreference.allCases.map(\.title) == ["Follow stock", "Orange", "Green"])
        #expect(CameraLensControlPosition.allCases.map(\.title) == ["Top right", "Above shutter"])
    }

    // MARK: - Accent resolution

    @Test func followStockReadsTheStocksLightTypeMetadata() {
        let followStock = CameraControlColorPreference.followStock
        // `"D"` and `"T"` are the stock metadata values, never parsed names.
        #expect(followStock.usesGreen(lightType: "D") == false)
        #expect(followStock.usesGreen(lightType: "T"))
        #expect(followStock.usesGreen(lightType: "t"))
        #expect(followStock.usesGreen(lightType: " T "))
        #expect(followStock.usesGreen(lightType: nil) == false)
        #expect(followStock.usesGreen(lightType: "") == false)
        // A stock's display-name-like string is not metadata: orange fallback.
        #expect(followStock.usesGreen(lightType: "Tungsten") == false)
        #expect(followStock.usesGreen(lightType: "Daylight") == false)
        #expect(CameraControlColorPreference.isTungsten(lightType: "T"))
        #expect(CameraControlColorPreference.isTungsten(lightType: nil) == false)
    }

    @Test func fixedOverridesIgnoreTheSelectedStock() {
        #expect(CameraControlColorPreference.orange.usesGreen(lightType: "T") == false)
        #expect(CameraControlColorPreference.orange.usesGreen(lightType: "D") == false)
        #expect(CameraControlColorPreference.orange.usesGreen(lightType: nil) == false)
        #expect(CameraControlColorPreference.green.usesGreen(lightType: "D"))
        #expect(CameraControlColorPreference.green.usesGreen(lightType: "T"))
        #expect(CameraControlColorPreference.green.usesGreen(lightType: nil))
    }

    @Test func resolvedAccentsReuseTheSharedTokens() {
        let orange = CameraControlColorPreference.orangeAccent
        let green = CameraControlColorPreference.greenAccent
        #expect(orange == SettingsControlChrome.halationOrange,
                "the orange accent must reuse the shared halation token")
        #expect(CameraControlColorPreference.followStock.color(lightType: "D") == orange)
        #expect(CameraControlColorPreference.followStock.color(lightType: "T") == green)
        // No stock, an unclassified stock and an empty light type are orange.
        #expect(CameraControlColorPreference.followStock.color(lightType: nil) == orange)
        #expect(CameraControlColorPreference.followStock.color(lightType: "") == orange)
        #expect(CameraControlColorPreference.followStock.color(lightType: "X") == orange)
        #expect(CameraControlColorPreference.orange.color(lightType: "T") == orange)
        #expect(CameraControlColorPreference.green.color(lightType: "D") == green)
    }

    @Test func switchingStockOnlyMovesFollowStock() {
        let followStock = CameraControlColorPreference.followStock
        #expect(followStock.color(lightType: "D") != followStock.color(lightType: "T"))
        #expect(CameraControlColorPreference.orange.color(lightType: "D")
            == CameraControlColorPreference.orange.color(lightType: "T"))
        #expect(CameraControlColorPreference.green.color(lightType: "D")
            == CameraControlColorPreference.green.color(lightType: "T"))
    }

    @Test func aDamagedStoredValueFallsBackToFollowStock() {
        // An unknown persisted value is Follow stock, so a tungsten stock is
        // still green rather than pinned orange.
        #expect(CameraControlColorPreference.resolvedAccent(storedValue: "chartreuse", lightType: "T")
            == CameraControlColorPreference.greenAccent)
        #expect(CameraControlColorPreference.resolvedAccent(storedValue: "", lightType: "D")
            == CameraControlColorPreference.orangeAccent)
        #expect(CameraControlColorPreference.resolvedAccent(storedValue: "orange", lightType: "T")
            == CameraControlColorPreference.orangeAccent)
    }

    // MARK: - Persistence

    @Test func controlColorPersistsUnderItsOwnKey() throws {
        let defaults = try store("controlColor")
        #expect(CameraControlColorPreference.load(from: defaults) == .followStock,
                "nothing is persisted before the first choice")

        CameraControlColorPreference.green.save(to: defaults)
        #expect(defaults.string(forKey: CameraControlColorPreference.preferenceKey) == "green")
        #expect(CameraControlColorPreference.load(from: defaults) == .green)

        CameraControlColorPreference.orange.save(to: defaults)
        #expect(CameraControlColorPreference.load(from: defaults) == .orange)

        CameraControlColorPreference.followStock.save(to: defaults)
        #expect(CameraControlColorPreference.load(from: defaults) == .followStock)
    }

    @Test func lensPlacementPersistsUnderItsOwnKey() throws {
        let defaults = try store("lensPosition")
        #expect(CameraLensControlPosition.load(from: defaults) == .topRight,
                "Top right is the migration default for existing users")

        CameraLensControlPosition.aboveShutter.save(to: defaults)
        #expect(defaults.string(forKey: CameraLensControlPosition.preferenceKey) == "aboveShutter")
        #expect(CameraLensControlPosition.load(from: defaults) == .aboveShutter)
    }

    @Test func theTwoPreferencesDoNotOverwriteEachOther() throws {
        let defaults = try store("independent")
        CameraControlColorPreference.green.save(to: defaults)
        CameraLensControlPosition.aboveShutter.save(to: defaults)
        #expect(CameraControlColorPreference.load(from: defaults) == .green)
        #expect(CameraLensControlPosition.load(from: defaults) == .aboveShutter)
    }

    @Test func unusableStoredValuesLoadAsDefaults() throws {
        let defaults = try store("garbage")
        defaults.set("not a choice", forKey: CameraControlColorPreference.preferenceKey)
        defaults.set("not a choice", forKey: CameraLensControlPosition.preferenceKey)
        #expect(CameraControlColorPreference.load(from: defaults) == .followStock)
        #expect(CameraLensControlPosition.load(from: defaults) == .topRight)

        // A value of the wrong type reads as absent, not as a crash.
        let mistyped = try store("mistyped")
        mistyped.set(3, forKey: CameraControlColorPreference.preferenceKey)
        mistyped.set(true, forKey: CameraLensControlPosition.preferenceKey)
        #expect(CameraControlColorPreference.load(from: mistyped) == .followStock)
        #expect(CameraLensControlPosition.load(from: mistyped) == .topRight)
    }
}
