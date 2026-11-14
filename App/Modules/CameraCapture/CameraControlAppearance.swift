import Foundation
import SwiftUI

/// The one persisted accent choice for the camera's controls, plus the pure
/// resolution from a stock's light type to the colour that accent paints.
///
/// The setting is presentation only. It never touches capture, white balance,
/// exposure ownership or rendered output, and it must not recolour stock identity
/// colours, confirmed-recording red or semantic warnings — those keep their own
/// meaning whatever this holds.
///
/// "Follow stock" reads the selected stock's daylight/tungsten *metadata*
/// (`FilmStockConfig.lightType`: `"D"` or `"T"`), which is derived from the
/// stock's white-balance temperature. Production code must never infer the light
/// type from a stock's display name. No stock, an unclassified stock and an
/// unrecognised persisted value all resolve deterministically to the shared
/// halation orange, so an install that never opens Settings looks exactly as it
/// did before this preference existed.
enum CameraControlColorPreference: String, CaseIterable, Identifiable, Sendable {
    case followStock
    case orange
    case green

    /// Shared by the Settings picker and the camera screen, so both resolve the
    /// same stored value.
    static let preferenceKey = "camera.controlColor"

    /// A missing or unrecognised value resolves here (the migration default).
    static let defaultValue: CameraControlColorPreference = .followStock

    /// Resolve a persisted raw value. Absent, empty or unrecognised values take
    /// `defaultValue` rather than pinning a colour the user never chose.
    static func resolved(_ raw: String) -> Self {
        Self(rawValue: raw) ?? defaultValue
    }

    /// The shared halation orange. Reused from `SettingsControlChrome` rather
    /// than re-declaring its rounded hex value, so the settings switches and the
    /// camera accent can never drift apart.
    static var orangeAccent: Color { SettingsControlChrome.halationOrange }

    /// The follow-stock tungsten green, `#c3db83`.
    static let greenAccent = Color(red: 195.0 / 255.0,
                                   green: 219.0 / 255.0,
                                   blue: 131.0 / 255.0)

    var id: String { rawValue }

    /// User-facing label. Plain words; the row's help copy explains what
    /// "Follow stock" actually reads.
    var title: String {
        switch self {
        case .followStock: "Follow stock"
        case .orange: "Orange"
        case .green: "Green"
        }
    }

    /// Whether the resolved accent is the tungsten green.
    ///
    /// Pure by design, so the resolution rules are testable without a rendered
    /// view: follow-stock asks the stock metadata, and both fixed choices ignore
    /// the stock entirely.
    func usesGreen(lightType: String?) -> Bool {
        switch self {
        case .green:
            return true
        case .orange:
            return false
        case .followStock:
            return Self.isTungsten(lightType: lightType)
        }
    }

    /// The resolved accent for the given stock light type.
    func color(lightType: String?) -> Color {
        usesGreen(lightType: lightType) ? Self.greenAccent : Self.orangeAccent
    }

    /// `lightType` is stock metadata, not a display name: `"T"` is tungsten and
    /// everything else — daylight `"D"`, `nil`, an empty string or an unexpected
    /// value — falls back to orange.
    static func isTungsten(lightType: String?) -> Bool {
        guard let lightType else { return false }
        return lightType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "T"
    }

    /// Convenience for the one place that hands the accent to the camera: the
    /// stored raw value and the committed stock's light type in, the environment
    /// colour out.
    static func resolvedAccent(storedValue: String, lightType: String?) -> Color {
        resolved(storedValue).color(lightType: lightType)
    }

    /// The persisted choice, or the default when nothing usable is stored.
    static func load(from defaults: UserDefaults = .standard) -> Self {
        resolved(defaults.string(forKey: preferenceKey) ?? "")
    }

    /// Persist this choice. `@AppStorage` writes the same key from Settings.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

/// Where the shooting screen presents the lens controls.
///
/// Presentation only: changing placement must not reset zoom, switch cameras or
/// create a second lens state, and both placements route through the existing
/// committed lens selection. Top right stays the migration default so an
/// existing install keeps the layout it had before the preference existed.
enum CameraLensControlPosition: String, CaseIterable, Identifiable, Sendable {
    case topRight
    case aboveShutter

    /// Shared by the Settings picker and the camera screen.
    static let preferenceKey = "camera.lensControlPosition"

    /// A missing or unrecognised value resolves here.
    static let defaultValue: CameraLensControlPosition = .topRight

    static func resolved(_ raw: String) -> Self {
        Self(rawValue: raw) ?? defaultValue
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight: "Top right"
        case .aboveShutter: "Above shutter"
        }
    }

    /// The persisted placement, or the default when nothing usable is stored.
    static func load(from defaults: UserDefaults = .standard) -> Self {
        resolved(defaults.string(forKey: preferenceKey) ?? "")
    }

    /// Persist this placement. `@AppStorage` writes the same key from Settings.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

/// Presentation only: never replaces the camera view or its state owners.
/// Minimal preserves the current interface for existing installs and unknown values.
enum CameraUIStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case minimal

    static let preferenceKey = "camera.uiStyle"
    static let defaultValue: Self = .minimal

    var id: String { rawValue }
    var title: String { self == .classic ? "Classic" : "Minimal" }

    static func resolved(_ raw: String) -> Self { Self(rawValue: raw) ?? defaultValue }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        resolved(defaults.string(forKey: preferenceKey) ?? "")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    /// Starting and draining a take count as capture busy, not just confirmed REC.
    static func canChange(captureBusy: Bool, photoCaptureBusy: Bool) -> Bool {
        !captureBusy && !photoCaptureBusy
    }
}

/// Which stock surface a press on the camera bar asks for.
///
/// Minimal offers both: a tap opens the short picker (stock, gauge, processing)
/// and a held press opens the full list with the sample preview. Classic has one
/// stock sheet, so it answers every press with the full list. The choice is
/// resolved before presentation, so the sheet never has to know the style.
enum CameraStockEntry: String, CaseIterable, Sendable {
    case compact
    case full

    /// How long a press has to be held to ask for the full list in Minimal.
    static let holdThreshold: TimeInterval = 0.5

    /// Classic ignores what was asked for: its single sheet is the full list.
    static func resolved(_ requested: Self, style: CameraUIStyle) -> Self {
        style == .classic ? .full : requested
    }

    /// Tap versus hold, resolved once so the bar and its tests agree.
    static func destination(style: CameraUIStyle, pressDuration: TimeInterval) -> Self {
        resolved(pressDuration >= holdThreshold ? .full : .compact, style: style)
    }
}

/// Independent presentation preference; no metering or image-pipeline input.
enum CameraRulerContrastPreference {
    static let preferenceKey = "camera.highContrastRulers"
    static let defaultValue = false

    static func backdropOpacity(style: CameraUIStyle, enabled: Bool) -> Double {
        style == .minimal && enabled ? 0.72 : 0
    }
}

private struct CameraRulerHighContrastKey: EnvironmentKey {
    static let defaultValue = CameraRulerContrastPreference.defaultValue
}

/// Shared by the exposure, focus, zoom and shutter rails; never changes layout.
private struct CameraRulerBackdrop: ViewModifier {
    @Environment(\.cameraUIStyle) private var style
    @Environment(\.cameraRulerHighContrast) private var highContrast
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(CameraRulerContrastPreference.backdropOpacity(style: style, enabled: highContrast)))
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func cameraRulerBackdrop(cornerRadius: CGFloat = 8) -> some View {
        modifier(CameraRulerBackdrop(cornerRadius: cornerRadius))
    }
}

private struct CameraUIStyleKey: EnvironmentKey {
    static let defaultValue: CameraUIStyle = .defaultValue
}

/// The resolved accent, handed down by the camera screen so every control and
/// selection surface paints one colour resolved in one place.
private struct CameraControlAccentKey: EnvironmentKey {
    static let defaultValue: Color = CameraControlColorPreference.orangeAccent
}

extension EnvironmentValues {
    var cameraRulerHighContrast: Bool {
        get { self[CameraRulerHighContrastKey.self] }
        set { self[CameraRulerHighContrastKey.self] = newValue }
    }

    var cameraUIStyle: CameraUIStyle {
        get { self[CameraUIStyleKey.self] }
        set { self[CameraUIStyleKey.self] = newValue }
    }

    /// Orange until the camera screen resolves the persisted preference and the
    /// committed stock's light type.
    var cameraControlAccent: Color {
        get { self[CameraControlAccentKey.self] }
        set { self[CameraControlAccentKey.self] = newValue }
    }
}
