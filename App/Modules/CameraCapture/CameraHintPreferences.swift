import Foundation

/// The single persisted switch behind Settings > Camera Tips.
///
/// It gates only the camera's *unsolicited advisory* cues: the "Too bright"
/// exposure rescue trigger and the stock-selector discovery nudge. Camera errors,
/// faults, recording failures, storage warnings and the live frame-rate badge
/// never consult it — those must stay visible whatever the user chose here.
///
/// The default is ON, so a fresh install behaves exactly as it did before the
/// switch existed.
enum CameraHintPreferences {
    /// Shared between the Settings row and the camera screen.
    static let showsAdvisoryTipsKey = "camera.showsAdvisoryTips"
    static let defaultShowsAdvisoryTips = true

    /// Resolves a stored value; absent or of the wrong type reads as ON, so a
    /// damaged preference can never silently silence the cues.
    static func showsAdvisoryTips(_ storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? defaultShowsAdvisoryTips
    }

    /// The one decision both advisory cues share: tips must be on, and — where a
    /// cue can only make sense on a live screen — the camera must be ready. A cue
    /// is never painted over a blocked camera.
    static func allowsAdvisoryCue(showsAdvisoryTips: Bool, isCameraReady: Bool = true) -> Bool {
        showsAdvisoryTips && isCameraReady
    }
}
