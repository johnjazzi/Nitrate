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
        // Only the labels rotate; the row and its drag coordinates stay fixed.
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
/// selected mode also paints its lowercase word beside its letter, so the mode
/// reads at a glance without any inactive word ever being spoken by VoiceOver.
///
/// Each control owns an equal share of the row and lays out the *full* word in
/// both states; the inactive word is transparent rather than removed. That keeps
/// the row's footprint identical as the active mode moves, and it means the row
/// never clips a selected word away — the whole "D develop" / "V video" string
/// is scaled down (via `minimumScaleFactor`) to fit the share it is handed. It
/// fits the real camera slots from 96pt up, where two controls still meet the
/// 44pt touch floor.
///
/// The parent owns the selection and the placement; the carousel only reports
/// taps and deliberate horizontal swipes back through `onSelect`. The hidden
/// photo mode is never laid out, never hit-testable and never announced.
struct CameraModeCarousel: View {
    let selected: CameraMode
    let enabled: Bool
    let onSelect: (CameraMode) -> Void
    let rotationDegrees: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed row height. Keeps the row from resizing as the active label changes,
    /// and is itself the minimum touch height.
    static let height: CGFloat = 44

    /// The narrowest width a control is allowed to shrink to, so both controls
    /// stay tappable inside the smallest real slot (96pt fits two 44pt targets).
    static let minimumControlWidth: CGFloat = 44

    private let itemSpacing: CGFloat = 6
    private let labelPadding: CGFloat = 3
    /// How far the composed label may scale down before it truncates. At the
    /// 96pt slot this keeps both words legible rather than clipped.
    private let minimumScale: CGFloat = 0.3

    init(selected: CameraMode, enabled: Bool, rotationDegrees: Double = 0,
         onSelect: @escaping (CameraMode) -> Void) {
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
        self.rotationDegrees = rotationDegrees
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
        Button {
            guard enabled else { return }
            onSelect(mode)
        } label: {
            GeometryReader { geometry in
                let quarterTurn = abs(rotationDegrees).truncatingRemainder(dividingBy: 180) == 90
                let faceWidth = quarterTurn ? geometry.size.height : geometry.size.width
                let faceHeight = quarterTurn ? geometry.size.width : geometry.size.height
                label(mode)
                    .padding(.horizontal, labelPadding)
                    .frame(width: faceWidth, height: faceHeight)
                    .rotationEffect(.degrees(rotationDegrees))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: Self.minimumControlWidth, maxWidth: .infinity,
                   minHeight: Self.height, maxHeight: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(mode.voiceLabel)
        .accessibilityIdentifier(mode.accessibilityIdentifier)
        .accessibilityAddTraits(mode == selected ? .isSelected : [])
    }

    /// The single composed label for a control: the always-visible capital
    /// followed by the lowercase word. The word is laid out in both states so
    /// the row's footprint is stable, but only the selected mode paints it —
    /// the unselected word is fully transparent, so it reserves its space
    /// without reading, and VoiceOver speaks the button's own label instead.
    ///
    /// It is one `Text` so `minimumScaleFactor` shrinks the whole string to the
    /// control's share; the selected word is scaled, never clipped.
    private func label(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        let letter = Text(mode.letter)
            .font(NitrateTypography.font(size: 14, relativeTo: .headline))
            .foregroundColor(isActive ? .orange : Color.white.opacity(0.45))
        let word = Text(" " + mode.title)
            .font(NitrateTypography.font(size: 12, relativeTo: .subheadline))
            .foregroundColor(isActive ? Color.white.opacity(0.9) : Color.white.opacity(0))
        return (letter + word)
            .lineLimit(1)
            .minimumScaleFactor(minimumScale)
    }

    // MARK: - Swipe

    func resolvedSwipe(_ translation: CGSize) -> CameraModeCarouselGesture.Outcome {
        guard enabled else { return .none }
        return CameraModeCarouselGesture.outcome(translation: translation, from: selected)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: CameraModeCarouselGesture.minimumTravel)
            .onEnded { value in
                guard enabled else { return }
                guard case let .select(mode) =
                        resolvedSwipe(value.translation)
                else { return }
                onSelect(mode)
            }
    }
}
