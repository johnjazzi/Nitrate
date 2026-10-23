import Foundation
import Testing

/// The record-button appearance is a persisted, discoverable preference. The app
/// shipped with a single face, so an install that never opens the picker — or
/// carries an unrecognised stored value — must keep that face rather than
/// silently switching to the new one. The setting and the shooting bar resolve
/// the same key and the same default, and the bar exposes the horizontal-inset
/// seam the alignment pass threads through.
struct RecordButtonAppearanceTests {
    private func store(_ name: String) throws -> UserDefaults {
        let suite = "RecordButtonAppearanceTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFreshInstallKeepsTheShippedClassicFace() throws {
        let defaults = try store("default")
        #expect(defaults.string(forKey: RecordButtonAppearance.preferenceKey) == nil,
                "Nothing is persisted before the picker is touched.")
        #expect(RecordButtonAppearance.stored(in: defaults) == .classic)
        #expect(RecordButtonAppearance.preferenceKey == "camera.recordButtonAppearance")
    }

    @Test func anUnknownOrMissingValueResolvesToClassic() {
        #expect(RecordButtonAppearance.resolved("") == .classic)
        #expect(RecordButtonAppearance.resolved("classic") == .classic)
        #expect(RecordButtonAppearance.resolved("modern") == .modern)
        #expect(RecordButtonAppearance.resolved("skeuomorphic") == .classic)
        #expect(RecordButtonAppearance.resolved("MODERN") == .classic)
    }

    @Test func aChosenFaceIsRemembered() throws {
        let defaults = try store("remembered")
        defaults.set(RecordButtonAppearance.modern.rawValue, forKey: RecordButtonAppearance.preferenceKey)
        #expect(RecordButtonAppearance.stored(in: defaults) == .modern)
        defaults.set(RecordButtonAppearance.classic.rawValue, forKey: RecordButtonAppearance.preferenceKey)
        #expect(RecordButtonAppearance.stored(in: defaults) == .classic)
    }

    @Test func anUnrecognisedStoredValueFallsBackToClassic() throws {
        let defaults = try store("garbage")
        defaults.set("not a face", forKey: RecordButtonAppearance.preferenceKey)
        #expect(RecordButtonAppearance.stored(in: defaults) == .classic)
    }

    @Test func everyCaseIsListedAndLabelledWithoutJargon() {
        #expect(RecordButtonAppearance.allCases == [.classic, .modern])
        #expect(RecordButtonAppearance.classic.title == "Classic")
        #expect(RecordButtonAppearance.modern.title == "Modern")
        for appearance in RecordButtonAppearance.allCases {
            #expect(appearance.rawValue == appearance.id)
            #expect(!appearance.title.isEmpty)
        }
    }

    @Test func theMorphIsBoundedAndBrief() {
        #expect(RecordButtonAppearanceTiming.morphDuration == 0.2)
        #expect(RecordButtonAppearanceTiming.morphDuration > 0)
        #expect(RecordButtonAppearanceTiming.morphDuration <= 0.25)
    }

    /// The bar reads the same key, resolves the same default and carries the
    /// stored `horizontalInset` seam the alignment pass passes in. Both app
    /// sources are already packaged fixtures, so no new allowlist entry is
    /// needed.
    @Test func theShootingBarSharesTheKeyDefaultAndInsetSeam() throws {
        let source = try String(contentsOf: TestRepository.url(
            for: "App/Modules/CameraCapture/CameraControlBar.swift"), encoding: .utf8)
        #expect(source.contains("@AppStorage(RecordButtonAppearance.preferenceKey)"))
        #expect(source.contains("RecordButtonAppearance.classic.rawValue"))
        #expect(source.contains("var horizontalInset: CGFloat = 16"))
        #expect(source.contains(".padding(.horizontal, horizontalInset)"))

        let stockHint = try #require(source.range(of: "let showsStockHint: Bool"))
        let inset = try #require(source.range(of: "var horizontalInset: CGFloat = 16"))
        #expect(stockHint.upperBound < inset.lowerBound,
                "The inset seam must trail `showsStockHint` so the sibling's `horizontalInset:` argument compiles.")
    }

    /// The picker must be discoverable in the camera/Preview section, not buried
    /// in the DEBUG-only block.
    @Test func theSettingOffersTheSameKeyOutsideDebug() throws {
        let source = try String(contentsOf: TestRepository.url(
            for: "App/Modules/Purchase/PurchaseView.swift"), encoding: .utf8)
        #expect(source.contains("@AppStorage(RecordButtonAppearance.preferenceKey)"),
                "The picker persists through the same key as the bar.")
        #expect(source.contains("Picker(\"Record button\""))

        let preview = try #require(source.range(of: "private var previewModeSection"))
        let picker = try #require(source.range(of: "Picker(\"Record button\""))
        let export = try #require(source.range(of: "private var exportSection"))
        #expect(preview.lowerBound < picker.lowerBound && picker.lowerBound < export.lowerBound,
                "The record-button picker lives in the camera/Preview section, before the export and DEBUG sections.")
    }
}
