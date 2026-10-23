import Foundation

/// Debug-only feature flags for the camera screen's manual-controls presentation.
///
/// The legacy manual-controls pop-up panel is retained for comparison, but it is
/// reachable only behind this user-owned debug switch. The flag defaults off and
/// is always resolved off in a Release build: the shipping screen shows the
/// in-frame master controls and never mounts the old panel, even on a device
/// that still carries the preference from a debug install.
enum CameraManualControlsFeatureFlags {
    /// Persisted debug switch that reopens the legacy manual-controls panel.
    static let legacyManualControlsKey = "camera.legacyManualControls"

    /// The flag's default. The legacy panel is off, so a fresh install — and
    /// every Release build — shows the in-frame master controls.
    static let legacyManualControlsDefault = false

    /// Whether this process was compiled with the debug configuration enabled.
    /// `#if DEBUG` is compile-time, so a Release binary cannot even ask.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Resolve the legacy-panel flag from the stored value and the build
    /// configuration. A Release build ignores the stored value entirely, so the
    /// legacy panel can never be reached in a shipping app; a debug build still
    /// honours the user-owned switch.
    static func resolvedLegacyManualControls(stored: Bool, isDebugBuild: Bool) -> Bool {
        isDebugBuild && stored
    }

    /// The resolved legacy-panel flag for this process.
    static var legacyManualControlsEnabled: Bool {
        resolvedLegacyManualControls(stored: UserDefaults.standard.bool(forKey: legacyManualControlsKey),
                                     isDebugBuild: isDebugBuild)
    }
}
