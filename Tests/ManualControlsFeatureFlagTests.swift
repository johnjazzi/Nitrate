import Foundation
import Testing

/// The debug-only feature flag that gates the legacy manual-controls panel.
///
/// The flag is user-owned and defaults off. A Release build must resolve it off
/// no matter what is stored, so the legacy panel can never be reached in a
/// shipping app even on a device that still carries the preference from a debug
/// install. The resolution rule is a pure function so the Release behaviour is
/// provable without a Release build (the screen itself is compiled once per
/// configuration and cannot be re-tested here).
struct ManualControlsFeatureFlagTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestRepository.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Pure resolution

    @Test func flagDefaultsOffWithTheDocumentedKey() {
        #expect(CameraManualControlsFeatureFlags.legacyManualControlsKey == "camera.legacyManualControls")
        #expect(CameraManualControlsFeatureFlags.legacyManualControlsDefault == false)
    }

    @Test func releaseResolvesLegacyPanelOffWhateverIsStored() {
        // The hard contract: in a Release build the legacy panel is unreachable
        // even when the stored preference says otherwise.
        #expect(CameraManualControlsFeatureFlags.resolvedLegacyManualControls(stored: true, isDebugBuild: false)
                == false)
        #expect(CameraManualControlsFeatureFlags.resolvedLegacyManualControls(stored: false, isDebugBuild: false)
                == false)
    }

    @Test func debugFollowsTheStoredFlag() {
        #expect(CameraManualControlsFeatureFlags.resolvedLegacyManualControls(stored: true, isDebugBuild: true))
        #expect(CameraManualControlsFeatureFlags.resolvedLegacyManualControls(stored: false, isDebugBuild: true)
                == false)
    }

    // MARK: - Source wiring

    @Test func screenGatesTheLegacyPanelAndKeepsTheInFrameDefault() throws {
        let screen = try source("App/ContentView.swift")
        // The old pop-up is mounted only with both the legacy state and the flag.
        #expect(screen.contains("if showManualControls, legacyManualControlsEnabled,"))
        // The flag is read through the resolver, conditional on DEBUG, and the
        // in-frame block is the default when it is off.
        #expect(screen.contains("resolvedLegacyManualControls("))
        #expect(screen.contains("CameraManualControlsFeatureFlags.legacyManualControlsKey"))
        #expect(screen.contains("else if showInlineManualControls {"))
        // It is a debug-only stored switch, never a Release-affecting literal.
        #expect(!screen.contains("legacyManualControlsStored = true"))
    }

    @Test func settingsExposesTheDebugOnlyLegacyToggle() throws {
        let settings = try source("App/Modules/Purchase/PurchaseView.swift")
        #expect(settings.contains("var legacyManualControlsEnabled: Binding<Bool> = .constant(false)"))
        #expect(settings.contains(#"Toggle("Legacy Manual Controls", isOn: legacyManualControlsEnabled)"#))
        // The row lives in the DEBUG-only settings section.
        let debugSection = try #require(settings.components(separatedBy: "private var debugSection").last)
        #expect(debugSection.contains(#""Legacy Manual Controls""#))
    }
}
