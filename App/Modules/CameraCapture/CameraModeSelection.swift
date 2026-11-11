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

    /// The lowercase title shown below the selected letter.
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

    static func visibleModes(photoAvailable: Bool) -> [CameraMode] {
        photoAvailable ? [.develop, .video, .photo] : visibleModes
    }
}

/// Selection state for the mode carousel, kept free of SwiftUI so the rules can
/// be exercised without rendering.
struct CameraModeSelection: Equatable, Sendable {
    private(set) var selected: CameraMode
    init(selected: CameraMode = .video) { self.selected = selected }
    @discardableResult
    mutating func select(_ mode: CameraMode, enabled: Bool, photoAvailable: Bool = false) -> Bool {
        guard enabled, CameraMode.visibleModes(photoAvailable: photoAvailable).contains(mode), mode != selected else { return false }
        selected = mode
        return true
    }
}
