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
///
/// The 44pt members here are Classic's geometry and remain the default contract.
/// Minimal uses the compact strip below instead: one 28pt disc per visible mode
/// with a 4pt gap, so the letters read 32pt apart while the whole group still
/// fits inside the slot with a whole, non-overlapping tap per cell.
enum CameraModeRowLayout {
    /// One honest mode target, in points. Also the fixed width of a strip cell.
    static let controlWidth: CGFloat = 44

    /// How far a letter is pulled in toward the selection so the peeking modes
    /// read as one group. It moves no live target — only the drawn glyph.
    static let peekInset: CGFloat = 6

    /// Minimal's drawn cell: one 28pt disc. It is also the cell's tap width, so
    /// a compact tap is a 28x44pt column — the row keeps its 44pt touch height.
    static let compactCellWidth: CGFloat = 28

    /// Visible space between two compact discs. 28pt disc + 4pt gap = a 32pt
    /// pitch, which keeps D/V/P reading as one group instead of a blob.
    static let compactGap: CGFloat = 4

    /// Centre-to-centre distance of two compact cells: 32pt.
    static var compactPitch: CGFloat { compactCellWidth + compactGap }

    /// Width of the whole compact group: n discs and n-1 gaps. Three modes need
    /// 92pt, so the group fits the 96pt floor the camera strip geometry allows.
    static func compactGroupWidth(visibleCount: Int) -> CGFloat {
        guard visibleCount > 0 else { return 0 }
        return CGFloat(visibleCount) * compactCellWidth + CGFloat(visibleCount - 1) * compactGap
    }

    /// Every compact cell fits whole inside `width`, so each one can be a live,
    /// non-overlapping tap target. A narrower slot offers no clipped target.
    static func compactGroupFits(width: CGFloat, visibleCount: Int) -> Bool {
        guard width.isFinite, width > 0, visibleCount > 0 else { return false }
        return width >= compactGroupWidth(visibleCount: visibleCount)
    }

    /// One compact cell's rect inside the slot, measured from its leading edge.
    /// The group is centred as a whole, so no cell is pushed by a 44pt offset
    /// and no cell can hang off the slot.
    static func compactCellRect(index: Int, slotWidth: CGFloat, visibleCount: Int) -> CGRect {
        guard visibleCount > 0, slotWidth.isFinite else { return .zero }
        let clamped = min(max(index, 0), visibleCount - 1)
        let leading = (slotWidth - compactGroupWidth(visibleCount: visibleCount)) / 2
        return CGRect(x: leading + CGFloat(clamped) * compactPitch,
                      y: 0,
                      width: compactCellWidth,
                      height: CameraModeCarousel.height)
    }

    /// Every visible mode's whole 44pt target fits inside `width`, so the whole
    /// row can be live.
    static func fullStripFits(width: CGFloat, visibleCount: Int, selectedIndex: Int = 0) -> Bool {
        guard width.isFinite, width > 0, visibleCount > 0,
              selectedIndex >= 0, selectedIndex < visibleCount else { return false }
        // Centering the selected cell makes an end selection asymmetric. Two
        // 44pt cells need 132pt, not 88pt, to keep the neighbor's full target.
        let cellsToEdge = max(selectedIndex, visibleCount - selectedIndex - 1)
        return width >= CGFloat(2 * cellsToEdge + 1) * controlWidth
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

/// Classic keeps the selected letter centred. Minimal paints it on one flat dark
/// disc and packs D/V/P into a 28pt cell on a 4pt gap, so the three letters read
/// as one tight group (32pt pitch) centred as a whole in the slot. Classic
/// restores the pre-minimal treatment — 44pt cells, a larger accent-coloured
/// letter with its full-size caption beneath and ghosted neighbours — without the
/// flat selection fill. The parent owns the selection.
///
/// Both styles share one interaction contract: every letter offered as a control
/// keeps a whole target, and no target is ever offered half off the slot. Minimal
/// keeps the row's 44pt touch height and gives each compact cell its own
/// non-overlapping 28x44pt tap; Classic keeps its 44pt cells and degrades a
/// neighbour to a decorative peek when its full target cannot fit. Swipe,
/// accessibility adjustment, refusal and availability are identical in both, so
/// no second interaction model exists to drift.
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
    /// Classic or Minimal presentation only. Selection, availability, refusal
    /// and swipe behaviour are identical in both, so no second selection state
    /// exists to drift.
    @Environment(\.cameraUIStyle) private var uiStyle

    private var isClassic: Bool { uiStyle == .classic }

    /// Fixed row height. Keeps the row from resizing as the active label
    /// changes, and is itself the minimum touch height.
    static let height: CGFloat = 44

    /// The selected target's fixed width — the touch floor it never shrinks
    /// below.
    static let minimumControlWidth: CGFloat = 44

    /// The flat dark fill behind the selected letter. Deliberately smaller than
    /// the 44pt classic target: the target is invisible, the fill is the state.
    /// It is exactly one Minimal cell wide, so the fill is the disc and the
    /// 32pt pitch is never widened by decoration.
    static let selectionFillSize: CGFloat = CameraModeRowLayout.compactCellWidth

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
            strip(width: proxy.size.width)
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

    /// Classic's rule, and the row's default 44pt contract: a letter is a live
    /// control only while its entire 44pt target fits in the slot. Narrow slots
    /// keep the centred target and degrade the neighbours to peeks rather than
    /// clipping a target in half. Minimal uses `compactGroupFits` instead.
    func isInteractive(_ mode: CameraMode, in width: CGFloat) -> Bool {
        guard visibleModes.contains(mode), width.isFinite else { return false }
        let centerOffset = CGFloat(abs(index(of: mode) - index(of: selected))) * Self.minimumControlWidth
        return centerOffset + Self.minimumControlWidth / 2 <= width / 2
    }

    private func fitsFullStrip(width: CGFloat) -> Bool {
        CameraModeRowLayout.fullStripFits(width: width, visibleCount: visibleModes.count,
                                         selectedIndex: index(of: selected))
    }

    /// One row per style. Classic keeps its 44pt cells nudged so the selected
    /// letter lands on the slot's centre; Minimal centres its whole 28pt-cell
    /// group and never offsets a cell, so no letter is pushed off the slot.
    @ViewBuilder
    private func strip(width: CGFloat) -> some View {
        if isClassic {
            classicStrip(width: width)
        } else {
            compactStrip(width: width)
        }
    }

    /// Classic: one row of 44pt cells nudged so the selected letter lands on the
    /// slot's centre. In a compact slot only the centred letter is a control;
    /// the neighbours are drawn as peeks.
    @ViewBuilder
    private func classicStrip(width: CGFloat) -> some View {
        let compact = !fitsFullStrip(width: width)
        let row = HStack(spacing: 0) {
            ForEach(visibleModes) { mode in
                item(mode, interactive: isInteractive(mode, in: width))
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

    /// Minimal: a 28pt disc per visible mode on a 4pt gap, the whole group
    /// centred in the slot by the frame around it. When every cell fits — the
    /// only case the 96pt strip floor produces — each cell stays its own
    /// labelled, non-overlapping 28x44pt button.
    @ViewBuilder
    private func compactStrip(width: CGFloat) -> some View {
        let allCellsFit = CameraModeRowLayout.compactGroupFits(width: width,
                                                               visibleCount: visibleModes.count)
        let row = HStack(spacing: CameraModeRowLayout.compactGap) {
            ForEach(visibleModes) { mode in
                compactItem(mode, interactive: allCellsFit)
            }
        }
        // Minimal seats the D/V/P group in the same borderless well as the other
        // camera clusters. The vertical inset keeps the fill off the row's full
        // 44pt touch height, and the frame after it keeps the slot's geometry, so
        // neither the well nor the discs move a cell or its target.
        .cameraWellBacking(cornerRadius: 10, verticalInset: 4)
        .frame(width: width, height: Self.height)

        if allCellsFit {
            row
        } else {
            // A slot narrower than the group would clip a cell, so the row
            // offers no half target: one announced element, swipe/adjust only.
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selected.voiceLabel)
                .accessibilityIdentifier(selected.accessibilityIdentifier)
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint(enabled ? "" : "Unavailable right now")
                .accessibilityAdjustableAction(adjust)
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

    /// One Classic mode control: a 44pt cell. When `interactive` it is a live,
    /// labelled button; when not it is a decorative peek that is never
    /// hit-testable or announced.
    private func item(_ mode: CameraMode, interactive: Bool) -> some View {
        let face = GeometryReader { geometry in
            let quarterTurn = abs(rotationDegrees).truncatingRemainder(dividingBy: 180) == 90
            let faceWidth = quarterTurn ? geometry.size.height : geometry.size.width
            let faceHeight = quarterTurn ? geometry.size.width : geometry.size.height
            classicLabel(mode)
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
                modeButton(mode, face: face)
            } else {
                face.accessibilityHidden(true)
            }
        }
    }

    /// One Minimal mode control: a 28pt-wide cell on the row's 44pt height. Each
    /// cell is its own tap, so the compact group offers deterministic,
    /// non-overlapping buttons instead of one wide target.
    private func compactItem(_ mode: CameraMode, interactive: Bool) -> some View {
        let face = GeometryReader { geometry in
            let quarterTurn = abs(rotationDegrees).truncatingRemainder(dividingBy: 180) == 90
            let faceWidth = quarterTurn ? geometry.size.height : geometry.size.width
            let faceHeight = quarterTurn ? geometry.size.width : geometry.size.height
            compactLabel(mode)
                .frame(width: faceWidth, height: faceHeight)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(width: CameraModeRowLayout.compactCellWidth, height: Self.height)
        .contentShape(Rectangle())

        return Group {
            if interactive {
                modeButton(mode, face: face)
            } else {
                face.accessibilityHidden(true)
            }
        }
    }

    /// The one button contract for both styles: same action, same refusal, same
    /// label, identifier, hint and selected trait.
    private func modeButton(_ mode: CameraMode, face: some View) -> some View {
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
        // The row stays tappable when blocked so the refusal can be spoken; say
        // the row is unavailable rather than "dimmed".
        .accessibilityHint(enabled ? "" : "Unavailable right now")
        .accessibilityAddTraits(mode == selected ? .isSelected : [])
    }

    /// Classic: the bare 14pt letter over its full-size 12pt caption — the old
    /// treatment, with no fill, ring or track, and both caption bands laid out
    /// so selection never changes row height.
    private func classicLabel(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        return VStack(spacing: 0) {
            Text(mode.letter)
                .font(NitrateTypography.font(size: 14, relativeTo: .headline))
                .foregroundColor(isActive ? controlAccent : Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(mode.title)
                .font(NitrateTypography.font(size: 12, relativeTo: .subheadline))
                .foregroundColor(Color.white.opacity(isActive ? 0.9 : 0))
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
        }
    }

    /// Minimal: the letter alone on its flat dark disc. At a 32pt pitch there is
    /// no honest room for a word caption — it would shrink below legibility and
    /// paint past the slot — so the selected mode reads through the accent
    /// letter and its disc. The spoken name is unchanged (see `modeButton`).
    private func compactLabel(_ mode: CameraMode) -> some View {
        let isActive = mode == selected
        return ZStack {
            if isActive { selectionFill }
            Text(mode.letter)
                .font(NitrateTypography.font(size: 14, relativeTo: .headline))
                .foregroundColor(isActive ? controlAccent : Color.white.opacity(0.45))
                // Large Dynamic Type must not grow the cell past the row.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: Self.selectionFillSize, height: Self.selectionFillSize)
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
