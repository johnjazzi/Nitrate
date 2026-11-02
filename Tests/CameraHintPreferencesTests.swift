import Foundation
import Testing

/// The persisted switch behind Settings > Camera Tips. It gates only the camera's
/// unsolicited advisory cues; camera errors, faults, recording failures, storage
/// warnings and the live frame-rate badge are never routed through it.
@Suite("Camera hint preferences")
struct CameraHintPreferencesTests {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "CameraHintPreferencesTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsToOnWhenNothingIsStored() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        #expect(CameraHintPreferences.defaultShowsAdvisoryTips)
        #expect(CameraHintPreferences.showsAdvisoryTips(store.object(
            forKey: CameraHintPreferences.showsAdvisoryTipsKey)))
        #expect(CameraHintPreferences.showsAdvisoryTips(nil))
    }

    @Test func readsAndWritesTheSharedPreferenceKey() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }

        store.set(false, forKey: CameraHintPreferences.showsAdvisoryTipsKey)
        #expect(!CameraHintPreferences.showsAdvisoryTips(store.object(
            forKey: CameraHintPreferences.showsAdvisoryTipsKey)))

        store.set(true, forKey: CameraHintPreferences.showsAdvisoryTipsKey)
        #expect(CameraHintPreferences.showsAdvisoryTips(store.object(
            forKey: CameraHintPreferences.showsAdvisoryTipsKey)))
    }

    /// A stale or hand-edited value of the wrong type must fall back to the
    /// shipped default rather than silently switching tips off.
    @Test func unknownStoredValueFallsBackToOn() throws {
        let (store, name) = try defaults()
        defer { store.removePersistentDomain(forName: name) }
        store.set("no", forKey: CameraHintPreferences.showsAdvisoryTipsKey)
        #expect(CameraHintPreferences.showsAdvisoryTips(store.object(
            forKey: CameraHintPreferences.showsAdvisoryTipsKey)))
    }

    @Test func offSuppressesAdvisoryCuesOnlyWhileTheCameraIsReady() {
        #expect(CameraHintPreferences.allowsAdvisoryCue(showsAdvisoryTips: true, isCameraReady: true))
        #expect(!CameraHintPreferences.allowsAdvisoryCue(showsAdvisoryTips: false, isCameraReady: true))
        #expect(!CameraHintPreferences.allowsAdvisoryCue(showsAdvisoryTips: true, isCameraReady: false))
        #expect(!CameraHintPreferences.allowsAdvisoryCue(showsAdvisoryTips: false, isCameraReady: false))
    }

    /// Wiring contract: the screen reads the same key the Settings row writes and
    /// gates both advisory cues behind one shared decision. Source text, not a
    /// runtime UI proof.
    @Test func screenReadsTheSharedKeyAndGatesBothAdvisoryCues() throws {
        let screen = try source("App/ContentView.swift")
        #expect(screen.contains("@AppStorage(CameraHintPreferences.showsAdvisoryTipsKey)"))
        #expect(screen.contains("CameraHintPreferences.allowsAdvisoryCue("))
        // The daylight rescue cue and the stock-selector nudge both read the gate.
        #expect(screen.contains("showsAdvisoryTips: showsAdvisoryTips,"))
        let rescue = try #require(screen.range(of: "private var shouldOfferDaylightRescue"))
        let rescueBody = screen[rescue.lowerBound...]
        #expect(rescueBody.prefix(600).contains("isAdvisoryCueAllowed"),
                "The rescue trigger's own decision must be gated, so the idle 60 badge stays reachable.")
        // `isActive` is the shared advisory gate: tips off ends the cue without
        // spending the once-per-launch hint.
        #expect(screen.contains("isActive: isStockHintCueAllowed,"))
        #expect(screen.contains(".onChange(of: showsAdvisoryTips)"),
                "Turning tips off clears the cue in the same beat.")
        // The idle-armed 60 badge keeps its own condition, so tips off still leaves a way back to 24 fps.
        #expect(screen.contains("!shouldOfferDaylightRescue, recordPresentation == .idle,"))
        // Critical surfaces never consult the preference.
        #expect(!screen.contains("showsAdvisoryTips && showsRecordingFailure"))
        #expect(!screen.contains("if showsAdvisoryTips, let storage"))
    }

    /// The Settings row reuses the existing toggle chrome and the shared key.
    @Test func settingsRowUsesTheExistingToggleAndSharedKey() throws {
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("CameraHintPreferences.showsAdvisoryTipsKey"))
        #expect(settings.contains("title: \"Camera Tips\""))
        let row = try #require(settings.range(of: "title: \"Camera Tips\""))
        #expect(settings[..<row.lowerBound].suffix(400).contains("SettingsToggleRow("))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.url(for: path), encoding: .utf8)
    }
}
