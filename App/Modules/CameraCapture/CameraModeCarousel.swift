import SwiftUI

/// Pure decision for a finished drag on the mode row. Free of SwiftUI so the
/// swipe rules can be exercised without rendering.
///
/// Exactly one outcome is produced per completed drag. A deliberate horizontal
/// swipe moves to the neighbouring *visible* mode; a vertical or ambiguous drag
/// produces nothing, so the row never intercepts a vertical scroll and never
/// fires mid-drag. Because the walk is confined to `visibleModes`, no swipe can
/// over-scroll past the last visible mode into the hidden photo slot.
enum CameraModeCarouselGesture {
    /// Shortest horizontal travel that counts as a deliberate swipe, in points.
    static let minimumTravel: CGFloat = 24

    /// How far horizontal travel must dominate vertical travel to count. A drag
    /// that is not clearly more horizontal than vertical is ignored.
    static let horizontalDominance: CGFloat = 1.5

    enum Outcome: Equatable {
        case select(CameraMode)
        case none
    }

    static func outcome(translation: CGSize,
                        from current: CameraMode,
                        visible: [CameraMode] = CameraMode.visibleModes) -> Outcome {
        let horizontal = translation.width
        let vertical = translation.height

        guard abs(horizontal) >= minimumTravel else { return .none }
        guard abs(horizontal) >= abs(vertical) * horizontalDominance else { return .none }
        guard let index = visible.firstIndex(of: current) else { return .none }

        let target = index + (horizontal < 0 ? 1 : -1)
        guard visible.indices.contains(target) else { return .none }
        return .select(visible[target])
    }
}

/// Compact mode row that sits below the shooting bar.
///
/// The row shows the visible mode letters D and V at all times. Only the
/// selected mode also shows its lowercase word beside its letter, so the mode
/// reads at a glance without any inactive word ever being spoken by VoiceOver.
/// The inactive word still reserves its layout space, so switching the active
/// mode cannot move the row's footprint.
///
/// The parent owns the selection and the placement; the carousel only reports
/// taps and deliberate horizontal swipes back through `onSelect`. The hidden
/// photo mode is never laid out, never hit-testable and never announced.
struct CameraModeCarousel: View {
    let selected: CameraMode
    let enabled: Bool
    let onSelect: (CameraMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed row height. Keeps the row from resizing as the active label changes.
    static let height: CGFloat = 52

    private let itemSpacing: CGFloat = 4
    private let labelSpacing: CGFloat = 6
    private let minimumHitHeight: CGFloat = 44

    init(selected: CameraMode, enabled: Bool, onSelect: @escaping (CameraMode) -> Void) {
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: itemSpacing) {
            ForEach(CameraMode.visibleModes) { mode in
                item(mode)
            }
        }
        .frame(height: Self.height)
        .opacity(enabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
        .simultaneousGesture(swipeGesture)
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: - Items

    private func item(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        return Button {
            guard enabled else { return }
            onSelect(mode)
        } label: {
            HStack(spacing: labelSpacing) {
                Text(mode.letter)
                    .font(NitrateTypography.font(size: 15, relativeTo: .headline))
                    .foregroundStyle(isActive ? Color.orange : Color.white.opacity(0.45))
                Text(mode.title)
                    .font(NitrateTypography.font(size: 13, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.9))
                    // The inactive word keeps its space but is neither painted
                    // nor exposed to VoiceOver.
                    .opacity(isActive ? 1 : 0)
                    .accessibilityHidden(!isActive)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: minimumHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(mode.voiceLabel)
        .accessibilityIdentifier(mode.accessibilityIdentifier)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Swipe

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: CameraModeCarouselGesture.minimumTravel)
            .onEnded { value in
                guard enabled else { return }
                guard case let .select(mode) =
                        CameraModeCarouselGesture.outcome(translation: value.translation, from: selected)
                else { return }
                onSelect(mode)
            }
    }
}
