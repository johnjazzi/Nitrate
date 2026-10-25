import Foundation

/// The shooting modes the camera row can offer.
///
/// `photo` is part of the closed set because the product's mode vocabulary is a
/// fixed D-V-P sequence, but it is intentionally **hidden**: it is absent from
/// `visibleModes`, so no carousel item, hit target or VoiceOver element is ever
/// built for it, and `CameraModeSelection` refuses to select it. Removing the
/// case later must not change any other behaviour.
enum CameraMode: String, CaseIterable, Identifiable, Sendable {
    case develop
    case video
    case photo

    var id: String { rawValue }

    /// The single capital shown in the row. Always visible for a visible mode,
    /// and independent of whether the mode is selected.
    var letter: String {
        switch self {
        case .develop: "D"
        case .video: "V"
        case .photo: "P"
        }
    }

    /// The lowercase word shown beside the letter, but only for the selected
    /// mode. Matches `rawValue` by definition.
    var title: String { rawValue }

    /// The spoken name used for the row's VoiceOver label.
    var voiceLabel: String {
        switch self {
        case .develop: "Develop"
        case .video: "Video"
        case .photo: "Photo"
        }
    }

    /// Stable accessibility identifier for the mode's control.
    var accessibilityIdentifier: String { "cameraMode.\(rawValue)" }

    /// The modes the carousel lays out, in reading order. `photo` is deliberately
    /// omitted so it can never appear in the layout, a hit target or VoiceOver.
    static let visibleModes: [CameraMode] = [.develop, .video]
}

/// Selection state for the mode carousel, kept free of SwiftUI so the rules can
/// be exercised without rendering.
///
/// The parent owns the instance and feeds the resulting `selected` back into the
/// view. The model never allows a move that would strand the UI on a hidden or
/// unavailable mode: the hidden photo mode, a disabled capture session and a
/// repeat selection are all rejected without changing state.
struct CameraModeSelection: Equatable, Sendable {
    private(set) var selected: CameraMode

    /// Opens on Video, the mode the shutter row starts in.
    init(selected: CameraMode = .video) {
        self.selected = selected
    }

    /// Moves to `mode` when it is a visible, enabled, different mode.
    ///
    /// Returns `true` only when the selection actually changed, so a caller can
    /// gate haptics or animations on a real transition.
    @discardableResult
    mutating func select(_ mode: CameraMode, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard CameraMode.visibleModes.contains(mode) else { return false }
        guard mode != selected else { return false }
        selected = mode
        return true
    }

    /// Returns to Video, the mode the parent restores after the Develop flow
    /// (the Process Video import) dismisses.
    mutating func returnToVideo() {
        selected = .video
    }
}
