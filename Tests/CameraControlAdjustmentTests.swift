import Foundation
import Testing

/// The Camera Control slide target is a persisted, discoverable preference.
/// Nothing is stored before the user touches it, so a fresh install — and any
/// unrecognised stored value — must resolve to Zoom; the key and the labels are
/// part of the shipped contract.
struct CameraControlAdjustmentTests {
    @Test func aFreshInstallResolvesToZoom() throws {
        let defaults = try store("default")
        #expect(defaults.string(forKey: CameraControlAdjustment.preferenceKey) == nil,
                "Nothing is persisted before the picker is touched.")
        #expect(CameraControlAdjustment(persistedValue: nil) == .zoom)
        #expect(CameraControlAdjustment.defaultValue == .zoom)
    }

    @Test func everyCaseRoundTripsThroughItsStoredValue() {
        for adjustment in CameraControlAdjustment.allCases {
            #expect(CameraControlAdjustment(persistedValue: adjustment.rawValue) == adjustment)
        }
    }

    @Test func missingOrUnrecognisedValuesTakeZoom() {
        #expect(CameraControlAdjustment(persistedValue: "") == .zoom)
        #expect(CameraControlAdjustment(persistedValue: "zoom") == .zoom)
        #expect(CameraControlAdjustment(persistedValue: "Exposure") == .zoom, "raw values are case-sensitive")
        #expect(CameraControlAdjustment(persistedValue: "adjusted") == .zoom)
        #expect(CameraControlAdjustment(persistedValue: "unknown") == .zoom)
    }

    @Test func thePreferenceKeyIsStable() {
        #expect(CameraControlAdjustment.preferenceKey == "cameraControlAdjustment")
    }

    @Test func aChosenControlIsRemembered() throws {
        let defaults = try store("remembered")
        for adjustment in CameraControlAdjustment.allCases {
            defaults.set(adjustment.rawValue, forKey: CameraControlAdjustment.preferenceKey)
            let stored = try #require(defaults.string(forKey: CameraControlAdjustment.preferenceKey))
            #expect(CameraControlAdjustment(persistedValue: stored) == adjustment)
        }
        defaults.set("not a control", forKey: CameraControlAdjustment.preferenceKey)
        let garbage = try #require(defaults.string(forKey: CameraControlAdjustment.preferenceKey))
        #expect(CameraControlAdjustment(persistedValue: garbage) == .zoom)
    }

    @Test func everyCaseIsListedLabelledAndIdentified() {
        #expect(CameraControlAdjustment.allCases == [.zoom, .exposure, .off])
        #expect(CameraControlAdjustment.zoom.title == "Zoom")
        #expect(CameraControlAdjustment.exposure.title == "Exposure")
        #expect(CameraControlAdjustment.off.title == "Off")
        for adjustment in CameraControlAdjustment.allCases {
            #expect(adjustment.id == adjustment.rawValue)
            #expect(!adjustment.title.isEmpty)
            #expect(!adjustment.title.contains("camera"), "labels stay plain, not jargon")
        }
    }

    private func store(_ name: String) throws -> UserDefaults {
        let suite = "CameraControlAdjustmentTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
