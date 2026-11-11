import Foundation

/// The persisted choice between the shipped skeuomorphic REC control and a flat
/// modern face. Both share one 84pt footprint and the same capture state
/// machine; the setting only changes what the button draws.
enum RecordButtonAppearance: String, CaseIterable, Identifiable, Sendable {
    /// The current physical plunger. It stays the default so an install that
    /// never opens the picker — or carries an unrecognised value — is unchanged.
    case classic
    /// A flat black disc with a red rim and red REC mark; a confirmed take fills
    /// the disc red and swaps the mark for a white stop square.
    case modern

    /// Read by the shooting bar's `@AppStorage` and written by the Settings
    /// picker, so both resolve the same stored value.
    static let preferenceKey = "camera.recordButtonAppearance"

    /// A missing or unrecognised value resolves to `classic`: the app shipped
    /// with that face, so nothing about an untouched install changes.
    static func resolved(_ value: String) -> Self { Self(rawValue: value) ?? .classic }

    /// Resolve the current preference from a store. Absent or unrecognised
    /// values take `classic`.
    static func stored(in defaults: UserDefaults) -> Self {
        resolved(defaults.string(forKey: preferenceKey) ?? "")
    }

    var id: String { rawValue }

    /// User-facing label. Plain words only — no "skeuomorphic", no "flat".
    var title: String {
        switch self {
        case .classic: "Classic"
        case .modern: "Modern"
        }
    }
}

/// Shared timing for the modern face's idle↔recording morph. Bounded so the
/// state change reads as immediate; Reduce Motion replaces it with a static
/// state switch.
enum RecordButtonAppearanceTiming {
    static let morphDuration: TimeInterval = 0.2
}
