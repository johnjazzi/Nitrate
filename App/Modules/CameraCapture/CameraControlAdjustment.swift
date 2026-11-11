import Foundation

/// Which control the Camera Control button's light-press slide adjusts.
///
/// The hardware button keeps its full-press behaviour whatever this holds: a full
/// press captures a photo, or starts and stops a recording. The preference only
/// chooses what the light press and slide drive — zoom, exposure or nothing — and
/// `.off` leaves the full press untouched. Zoom is the default so an install that
/// never opens Settings, or carries an unrecognised stored value, behaves as the
/// app did before the setting existed.
enum CameraControlAdjustment: String, CaseIterable, Identifiable, Sendable {
    case zoom
    case exposure
    case off

    /// Shared by the Settings picker and the camera screen, so both resolve the
    /// same stored value.
    static let preferenceKey = "cameraControlAdjustment"

    /// A missing or unrecognised value resolves here.
    static let defaultValue: CameraControlAdjustment = .zoom

    /// Resolve a persisted raw value. Absent, empty or unrecognised values take
    /// `defaultValue` rather than disabling a control the user never turned off.
    init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var id: String { rawValue }

    /// User-facing label. Plain words only — "Off" describes the slide only, the
    /// full press still captures, which the row's help copy spells out.
    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .exposure: "Exposure"
        case .off: "Off"
        }
    }
}
