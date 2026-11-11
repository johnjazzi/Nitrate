import Foundation
import Testing

/// The house exposure is a persisted preference. Every install — including one
/// that has never touched the EV control — starts at -1.2 EV, and whatever the
/// user then chooses is remembered across camera sessions and app launches.
struct CameraExposureBiasPreferenceTests {
    private func store(_ name: String) throws -> UserDefaults {
        let suite = "CameraExposureBiasPreferenceTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func everyInstallStartsWithTheHouseExposure() throws {
        let defaults = try store("default")
        #expect(CameraExposureBiasPreference.storedValue(in: defaults) == nil,
                "Nothing is persisted before the first session.")
        #expect(CameraExposureBiasPreference.load(from: defaults) == -1.2)
        #expect(CameraExposureBiasPreference.defaultValue == -1.2)
        #expect(CameraExposureBiasPreference.preferenceKey == "camera.exposureBiasEV")
    }

    @Test func theUsersOwnValueIsRemembered() throws {
        let defaults = try store("remembered")
        CameraExposureBiasPreference.save(-2.5, to: defaults)
        #expect(CameraExposureBiasPreference.load(from: defaults) == -2.5)
        CameraExposureBiasPreference.save(0.7, to: defaults)
        #expect(CameraExposureBiasPreference.load(from: defaults) == 0.7)
    }

    @Test func deliberateNeutralIsNotMistakenForUnset() throws {
        let defaults = try store("neutral")
        CameraExposureBiasPreference.save(0, to: defaults)
        let stored = try #require(CameraExposureBiasPreference.storedValue(in: defaults))
        #expect(stored == 0)
        #expect(CameraExposureBiasPreference.load(from: defaults) == 0,
                "A user who chose neutral keeps it; only a missing value takes the default.")
    }

    @Test func unusableStoredValuesFallBackToTheDefault() throws {
        let defaults = try store("garbage")
        defaults.set("not a number", forKey: CameraExposureBiasPreference.preferenceKey)
        #expect(CameraExposureBiasPreference.load(from: defaults) == -1.2)
        #expect(CameraExposureBiasPreference.resolved(nil) == -1.2)
        #expect(CameraExposureBiasPreference.resolved(.nan) == -1.2)
        #expect(CameraExposureBiasPreference.resolved(.infinity) == -1.2)
        #expect(CameraExposureBiasPreference.resolved(-.infinity) == -1.2)
    }

    @Test func savingNonFiniteInputIsRefused() throws {
        let defaults = try store("nonfinite")
        CameraExposureBiasPreference.save(.nan, to: defaults)
        #expect(CameraExposureBiasPreference.storedValue(in: defaults) == nil)
        CameraExposureBiasPreference.save(.infinity, to: defaults)
        #expect(CameraExposureBiasPreference.storedValue(in: defaults) == nil)
        // The preference stores the user's value as-is: the active device's
        // ±3 EV range does the clamping, and that happens in the view model.
        CameraExposureBiasPreference.save(-4, to: defaults)
        #expect(CameraExposureBiasPreference.load(from: defaults) == -4)
    }

    /// The default is inside the range every device permits, so the house
    /// exposure is reachable without being clamped on any hardware.
    @Test func theDefaultFitsTheDevicesExposureRange() {
        let fallbackRange: ClosedRange<Float> = -3...3
        #expect(CameraExposureBiasPreference.defaultValue >= fallbackRange.lowerBound)
        #expect(CameraExposureBiasPreference.defaultValue <= fallbackRange.upperBound)
    }

    /// The value must reach the configured session, and must not be reset at the
    /// foreground boundary the way the session-only frame rate is.
    @Test func theViewModelStartsFromThePreferenceAndNeverResetsIt() throws {
        let camera = try source("App/Modules/CameraCapture/CameraViewModel.swift")
        #expect(camera.contains("var liveExposureBias: Float = CameraExposureBiasPreference.load()"))
        #expect(camera.contains("CameraExposureBiasPreference.save(clamped)"),
                "A user change is persisted after device clamping.")
        #expect(camera.contains("session.setExposureBiasEV(videoExposureBeforePhoto?.2 ?? liveExposureBias)"),
                "The persisted value must be pushed onto the configured session.")

        let apply = try #require(camera.range(of: "session.setExposureBiasEV(videoExposureBeforePhoto?.2 ?? liveExposureBias)"))
        let pin = try #require(camera.range(of: "session.enableShutterPriority()"))
        #expect(apply.lowerBound < pin.lowerBound,
                "It must be applied before shutter priority pins the first metered frame.")

        let boundaryStart = try #require(camera.range(of: "func onSceneInactive()"))
        let boundaryEnd = try #require(camera.range(of: "private func activateCameraIfNeeded()"))
        let boundary = camera[boundaryStart.upperBound..<boundaryEnd.lowerBound]
        #expect(!boundary.contains("liveExposureBias"),
                "A foreground-session boundary resets the frame rate, never the EV preference.")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }
}
