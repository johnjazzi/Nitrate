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

/// The selected mode stays centered, with its title below and ghosted neighbors.
/// Slots below 132pt use swipes and accessibility adjustment for the neighbor,
/// preserving the centered 44pt target. The parent owns the selection.
struct CameraModeCarousel: View {
    let selected: CameraMode
    let enabled: Bool
    let onSelect: (CameraMode) -> Void
    let rotationDegrees: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed row height. Keeps the row from resizing as the active label
    /// changes, and is itself the minimum touch height.
    static let height: CGFloat = 44

    /// The selected target's fixed width — the touch floor it never shrinks
    /// below. Also one control's share of the centred pair.
    static let minimumControlWidth: CGFloat = 44

    /// The narrowest width that shows the centred 44pt target and a full
    /// adjacent 44pt neighbour without overlap: 2 × (44/2 + 44) = 132pt. Below
    /// it the row uses the compact fallback.
    static let compactThreshold: CGFloat = minimumControlWidth * 3

    private let labelPadding: CGFloat = 3
    /// How far the caption may scale down before it truncates.
    private let minimumScale: CGFloat = 0.5

    init(selected: CameraMode, enabled: Bool, rotationDegrees: Double = 0,
         onSelect: @escaping (CameraMode) -> Void) {
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
        self.rotationDegrees = rotationDegrees
    }

    var body: some View {
        GeometryReader { proxy in
            strip(compact: proxy.size.width < Self.compactThreshold)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .frame(height: Self.height)
        .opacity(enabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
        .simultaneousGesture(swipeGesture)
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: - Layout

    @ViewBuilder
    private func strip(compact: Bool) -> some View {
        if compact {
            compactStrip
        } else {
            fullStrip
        }
    }

    /// The centred target with a full, live neighbour immediately beside it.
    /// The pair is nudged off its own centre so the *selected* target lands on
    /// the row's centre.
    private var fullStrip: some View {
        HStack(spacing: 0) {
            ForEach(CameraMode.visibleModes) { mode in
                item(mode, interactive: true)
            }
        }
        .fixedSize()
        .offset(x: centeringOffset)
    }

    /// The compact fallback: the centred target stays live, the neighbour is a
    /// decorative ghost, and the adjustment action still moves the selection.
    private var compactStrip: some View {
        ZStack {
            item(neighbour, interactive: false)
                .offset(x: selected == .develop ? Self.minimumControlWidth : -Self.minimumControlWidth)
            item(selected, interactive: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected.voiceLabel)
        .accessibilityIdentifier(selected.accessibilityIdentifier)
        .accessibilityAddTraits(.isSelected)
        .accessibilityAdjustableAction(adjust)
        .disabled(!enabled)
    }

    /// Shifts the centred pair so the selected mode — the leading half when
    /// Develop is selected, the trailing half when Video is — lands on centre.
    /// The whole block slides as the selection changes, animating both letters.
    private var centeringOffset: CGFloat {
        let index = CGFloat(CameraMode.visibleModes.firstIndex(of: selected) ?? 0)
        return (1 - 2 * index) * (Self.minimumControlWidth / 2)
    }

    /// The other visible mode, drawn as the ghosted neighbour.
    private var neighbour: CameraMode {
        CameraMode.visibleModes.first { $0 != selected } ?? selected
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard enabled else { return }
        switch direction {
        case .increment: if selected == .develop { onSelect(.video) }
        case .decrement: if selected == .video { onSelect(.develop) }
        default: break
        }
    }

    // MARK: - Items

    /// One mode control. When `interactive` it is a live, labelled button; when
    /// not it is a decorative ghost that is never hit-testable or announced.
    private func item(_ mode: CameraMode, interactive: Bool) -> some View {
        let face = GeometryReader { geometry in
            let quarterTurn = abs(rotationDegrees).truncatingRemainder(dividingBy: 180) == 90
            let faceWidth = quarterTurn ? geometry.size.height : geometry.size.width
            let faceHeight = quarterTurn ? geometry.size.width : geometry.size.height
            label(mode)
                .padding(.horizontal, labelPadding)
                .frame(width: faceWidth, height: faceHeight)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: geometry.size.width, height: geometry.size.height)
                // Bring the ghost inward without moving either 44pt touch target.
                .offset(x: mode == selected ? 0 : (mode == .develop ? 6 : -6))
        }
        .frame(width: Self.minimumControlWidth, height: Self.height)
        .contentShape(Rectangle())

        return Group {
            if interactive {
                Button {
                    guard enabled else { return }
                    onSelect(mode)
                } label: {
                    face
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(mode.voiceLabel)
                .accessibilityIdentifier(mode.accessibilityIdentifier)
                .accessibilityAddTraits(mode == selected ? .isSelected : [])
            } else {
                face.accessibilityHidden(true)
            }
        }
    }

    /// Keep both caption bands laid out so selection never changes row height.
    private func label(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        return VStack(spacing: 0) {
            Text(mode.letter)
                .font(NitrateTypography.font(size: 14, relativeTo: .headline))
                .foregroundColor(isActive ? .orange : Color.white.opacity(0.45))
            Text(mode.title)
                .font(NitrateTypography.font(size: 12, relativeTo: .subheadline))
                .foregroundColor(Color.white.opacity(isActive ? 0.9 : 0))
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
        }
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
