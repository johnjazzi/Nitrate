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

/// Pure decision for a tap on a mode letter. A blocked row is dimmed, not dead:
/// the tap is answered with the reason instead of being swallowed, so the
/// operator never has to read a permanent "you cannot change modes" banner over
/// a running take to learn why the row is grey.
enum CameraModeRowTap: Equatable {
    case select(CameraMode)
    case refused(CameraMode)

    static func outcome(for mode: CameraMode, enabled: Bool) -> CameraModeRowTap {
        enabled ? .select(mode) : .refused(mode)
    }
}

/// How the row spends a given slot width. A 44pt letter is a control only while
/// its whole target fits inside the slot; a neighbour whose target would be cut
/// is a decorative peek, so the row never offers a half tap area. Pure, so the
/// rule is exercised without rendering.
enum CameraModeRowLayout {
    /// One honest mode target, in points. Also the fixed width of a strip cell.
    static let controlWidth: CGFloat = 44

    /// How far a letter is pulled in toward the selection so the peeking modes
    /// read as one group. It moves no live target — only the drawn glyph.
    static let peekInset: CGFloat = 6

    /// Every visible mode's whole 44pt target fits inside `width`, so the whole
    /// row can be live.
    static func fullStripFits(width: CGFloat, visibleCount: Int) -> Bool {
        guard width.isFinite, width > 0, visibleCount > 0 else { return false }
        return width >= CGFloat(visibleCount) * controlWidth
    }

    /// Shifts the fixed-width strip so the selected letter — not the strip —
    /// lands on the slot's centre. One 44pt cell per visible mode.
    static func centeringOffset(selectedIndex: Int, visibleCount: Int) -> CGFloat {
        guard visibleCount > 0 else { return 0 }
        let index = CGFloat(min(max(selectedIndex, 0), visibleCount - 1))
        return (CGFloat(visibleCount - 1) - 2 * index) * (controlWidth / 2)
    }

    /// The drawn pull of one letter toward the selection. Zero for the selected
    /// mode, so the accent letter stays exactly centred.
    static func letterOffset(index: Int, selectedIndex: Int) -> CGFloat {
        index == selectedIndex ? 0 : (index < selectedIndex ? peekInset : -peekInset)
    }
}

/// The selected mode stays centred on one flat dark fill, with the neighbouring
/// available modes peeking in from the slot's edges. There is no track, ring or
/// raised face: selection reads through the resolved accent and a quiet caption.
/// The parent owns the selection.
///
/// Every letter offered as a control keeps its whole 44pt target inside the
/// slot. When the slot is too narrow for that (three visible modes in a narrow
/// strip), the neighbours become decorative peeks and the existing swipe and
/// accessibility adjustment still move the selection.
struct CameraModeCarousel: View {
    let selected: CameraMode
    let enabled: Bool
    let onSelect: (CameraMode) -> Void
    let rotationDegrees: Double
    var photoAvailable = false
    /// Called with the tapped letter while the row is blocked, so the refusal
    /// can be said out loud instead of the row going silent.
    var onBlockedSelect: ((CameraMode) -> Void)?
    private var visibleModes: [CameraMode] { CameraMode.visibleModes(photoAvailable: photoAvailable) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one resolved control accent shared with the rest of the camera
    /// chrome. The appearance layer owns its value and its fallback, so the row
    /// never invents a colour of its own.
    @Environment(\.cameraControlAccent) private var controlAccent: Color

    /// Fixed row height. Keeps the row from resizing as the active label
    /// changes, and is itself the minimum touch height.
    static let height: CGFloat = 44

    /// The selected target's fixed width — the touch floor it never shrinks
    /// below.
    static let minimumControlWidth: CGFloat = 44

    /// The flat dark fill behind the selected letter. Deliberately smaller than
    /// the 44pt target: the target is invisible, the fill is the state.
    static let selectionFillSize: CGFloat = 28

    private let labelPadding: CGFloat = 3
    /// How far the caption may scale down before it truncates.
    private let minimumScale: CGFloat = 0.5

    init(selected: CameraMode, enabled: Bool, rotationDegrees: Double = 0,
         onSelect: @escaping (CameraMode) -> Void, photoAvailable: Bool = false,
         onBlockedSelect: ((CameraMode) -> Void)? = nil) {
        self.selected = selected
        self.enabled = enabled
        self.onSelect = onSelect
        self.rotationDegrees = rotationDegrees
        self.photoAvailable = photoAvailable
        self.onBlockedSelect = onBlockedSelect
    }

    var body: some View {
        GeometryReader { proxy in
            strip(compact: !fitsFullStrip(width: proxy.size.width))
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

    /// A letter is a live control only while its entire 44pt target fits in the
    /// slot. Narrow slots keep the centred target and degrade the neighbours to
    /// peeks rather than clipping a target in half.
    func isInteractive(_ mode: CameraMode, in width: CGFloat) -> Bool {
        mode == selected
            || CameraModeRowLayout.fullStripFits(width: width, visibleCount: visibleModes.count)
    }

    private func fitsFullStrip(width: CGFloat) -> Bool {
        CameraModeRowLayout.fullStripFits(width: width, visibleCount: visibleModes.count)
    }

    /// One row of 44pt cells nudged so the selected letter lands on the slot's
    /// centre. In a compact slot only the centred letter is a control; the
    /// neighbours are drawn as peeks.
    @ViewBuilder
    private func strip(compact: Bool) -> some View {
        let row = HStack(spacing: 0) {
            ForEach(visibleModes) { mode in
                item(mode, interactive: !compact || mode == selected)
            }
        }
        .fixedSize()
        .offset(x: centeringOffset)

        if compact {
            // One announced, adjustable element — the peeks are decoration and
            // the swipe/adjust action owns the neighbour.
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selected.voiceLabel)
                .accessibilityIdentifier(selected.accessibilityIdentifier)
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint(enabled ? "" : "Unavailable right now")
                .accessibilityAdjustableAction(adjust)
        } else {
            row
        }
    }

    private var centeringOffset: CGFloat {
        CameraModeRowLayout.centeringOffset(selectedIndex: index(of: selected),
                                            visibleCount: visibleModes.count)
    }

    private func index(of mode: CameraMode) -> Int {
        visibleModes.firstIndex(of: mode) ?? 0
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard enabled else { return }
        switch direction {
        case .increment:
            if case .select(let mode) = resolvedSwipe(CGSize(width: -60, height: 0)) { onSelect(mode) }
        case .decrement:
            if case .select(let mode) = resolvedSwipe(CGSize(width: 60, height: 0)) { onSelect(mode) }
        default: break
        }
    }

    // MARK: - Items

    /// One mode control. When `interactive` it is a live, labelled button; when
    /// not it is a decorative peek that is never hit-testable or announced.
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
                // Bring a peeking letter inward without moving either 44pt
                // touch target; the selected letter is never moved.
                .offset(x: CameraModeRowLayout.letterOffset(index: index(of: mode),
                                                            selectedIndex: index(of: selected)))
        }
        .frame(width: Self.minimumControlWidth, height: Self.height)
        .contentShape(Rectangle())

        return Group {
            if interactive {
                Button {
                    switch resolvedTap(mode) {
                    case let .select(mode): onSelect(mode)
                    case let .refused(mode): onBlockedSelect?(mode)
                    }
                } label: {
                    face
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.voiceLabel)
                .accessibilityIdentifier(mode.accessibilityIdentifier)
                // The row stays tappable when blocked so the refusal can be
                // spoken; say the row is unavailable rather than "dimmed".
                .accessibilityHint(enabled ? "" : "Unavailable right now")
                .accessibilityAddTraits(mode == selected ? .isSelected : [])
            } else {
                face.accessibilityHidden(true)
            }
        }
    }

    /// Keep both caption bands laid out so selection never changes row height.
    /// Only the selected mode paints its caption, and it stays quiet: small,
    /// dim and clear of the accent used for the letter.
    private func label(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        return VStack(spacing: 1) {
            ZStack {
                if isActive { selectionFill }
                Text(mode.letter)
                    .font(NitrateTypography.font(size: 14, relativeTo: .headline))
                    .foregroundColor(isActive ? controlAccent : Color.white.opacity(0.45))
                    // Large Dynamic Type must not push the caption out of the
                    // fixed 44pt row.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: Self.selectionFillSize, height: Self.selectionFillSize)
            Text(mode.title)
                .font(NitrateTypography.font(size: 10, relativeTo: .caption2))
                .foregroundColor(Color.white.opacity(isActive ? 0.75 : 0))
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
        }
    }

    /// A flat, accent-matched dark fill — no stroke, gradient, shadow or nested
    /// ring. The accent at low opacity over charcoal resolves to a dark olive
    /// for green and a dark warm neutral for orange, so the fill follows the one
    /// shared accent without a second preference.
    private var selectionFill: some View {
        Circle()
            .fill(Color(white: 0.10))
            .overlay { Circle().fill(controlAccent.opacity(0.18)) }
    }

    // MARK: - Swipe

    func resolvedTap(_ mode: CameraMode) -> CameraModeRowTap {
        CameraModeRowTap.outcome(for: mode, enabled: enabled)
    }

    func resolvedSwipe(_ translation: CGSize) -> CameraModeCarouselGesture.Outcome {
        guard enabled else { return .none }
        return CameraModeCarouselGesture.outcome(translation: translation, from: selected, visible: visibleModes)
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
