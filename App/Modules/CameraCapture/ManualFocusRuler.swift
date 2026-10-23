import SwiftUI

/// Pure scale/behaviour for the in-frame manual-focus ruler. The ruler shows a
/// raw normalised lens position (0…1), never a fabricated distance: this is the
/// same value the hardware locks, mapped to the physical track.
enum ManualFocusRulerScale {
    /// One VoiceOver / step increment, in raw lens-position units.
    static let step: Double = 0.01

    /// Clamp a raw lens position into 0…1. Non-finite input falls back to the
    /// mid travel rather than pinning the lens to an extreme.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    /// Fraction down the physical track for a lens position: 0 at the top
    /// (lens position 1, far) and 1 at the bottom (lens position 0, near), so
    /// the index reads the same way the lens travels.
    static func indexFraction(lensPosition: Double) -> Double {
        guard lensPosition.isFinite else { return 0.5 }
        return min(max(1 - lensPosition, 0), 1)
    }

    /// Lens position for a drag `offset` from the top of a `length`-long track.
    /// Nil for a non-finite offset or a zero-length track.
    static func lensPosition(offsetFromTop: Double, length: Double) -> Double? {
        guard offsetFromTop.isFinite, length.isFinite, length > 0 else { return nil }
        return clamped(1 - offsetFromTop / length)
    }

    /// One bounded adjustment, clamped to the raw lens range.
    static func adjusted(lensPosition: Double, by delta: Double) -> Double {
        clamped((lensPosition.isFinite ? lensPosition : 0.5) + delta)
    }
}

/// One session-only manual-focus stop. It carries a stable identity so a hold
/// that grabs a marker keeps editing that same marker as it is dragged, and it
/// stores the raw lens position so a tap can snap focus back to it. Stops live
/// only for the process lifetime; nothing persists them between sessions.
struct ManualFocusStop: Identifiable, Equatable, Sendable {
    let id: UUID
    var lensPosition: Double

    /// The convenience initialiser mints a fresh identity unless one is supplied,
    /// so call sites that only know a position still get a distinct marker.
    init(id: UUID = UUID(), lensPosition: Double) {
        self.id = id
        self.lensPosition = lensPosition
    }
}

/// Pure, testable policy for editing the manual-focus stops: the three-stop
/// ceiling, clamped add/move/delete, the endpoint deletion bands and the nearest
/// marker a tap or VoiceOver action snaps to. Kept free of SwiftUI so the ruler
/// view stays a thin renderer over these rules.
enum ManualFocusStopEdit {
    /// At most three stops can be placed at once.
    static let maximumStops = 3

    /// Fraction of the track at each end that removes a stop dragged into it.
    static let removalBand: Double = 0.10

    /// Finger travel, in points, that separates a focus drag from a hold or tap.
    static let focusDragThreshold: Double = 6

    /// Finger travel allowed during a hold before it becomes an ordinary drag.
    static let holdSlop: Double = 12

    /// Seconds a touch must rest before it creates or grabs a stop.
    static let holdDuration: Double = 0.35

    /// The widest fraction of the track a marker stays grabbable across. A short
    /// track caps here rather than letting a point-scaled tolerance swallow the
    /// whole rail.
    static let maximumHitTolerance: Double = 0.06

    /// Finger travel in points that maps to a full marker grab.
    static let hitSlop: Double = 14

    /// Which end of the track a dragged stop has reached.
    enum RemovalEdge: Equatable {
        case top
        case bottom
    }

    static func clamped(_ value: Double) -> Double {
        ManualFocusRulerScale.clamped(value)
    }

    static func isAtCapacity(_ stops: [ManualFocusStop]) -> Bool {
        stops.count >= maximumStops
    }

    /// Appends a stop at a clamped position. A press when the rail already holds
    /// the maximum returns the set unchanged, so a fourth press is a no-op.
    static func adding(_ stops: [ManualFocusStop], lensPosition: Double) -> [ManualFocusStop] {
        guard !isAtCapacity(stops) else { return stops }
        return stops + [ManualFocusStop(lensPosition: clamped(lensPosition))]
    }

    /// Moves the stop with `id`, keeping every identity stable. An unknown id is
    /// a no-op so a stale grab never creates or reorders markers.
    static func moving(_ stops: [ManualFocusStop], id: UUID, lensPosition: Double) -> [ManualFocusStop] {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return stops }
        var updated = stops
        updated[index].lensPosition = clamped(lensPosition)
        return updated
    }

    /// Removes the stop with `id`; an unknown id is a no-op.
    static func removing(_ stops: [ManualFocusStop], id: UUID) -> [ManualFocusStop] {
        stops.filter { $0.id != id }
    }

    /// The marker nearest `position`, or nil when nothing sits within
    /// `tolerance`. Used for a tap snap and for grabbing an existing marker.
    static func snapTarget(_ stops: [ManualFocusStop],
                           toLensPosition position: Double,
                           tolerance: Double) -> ManualFocusStop? {
        guard position.isFinite, tolerance >= 0, !stops.isEmpty else { return nil }
        guard let nearest = stops.min(by: {
            abs($0.lensPosition - position) < abs($1.lensPosition - position)
        }) else { return nil }
        return abs(nearest.lensPosition - position) <= tolerance ? nearest : nil
    }

    /// A point-scaled grab tolerance: markers stay comfortably hittable on a long
    /// track without a short track letting one swallow the rail.
    static func hitTolerance(length: Double) -> Double {
        guard length.isFinite, length > 0 else { return maximumHitTolerance }
        return min(maximumHitTolerance, hitSlop / length)
    }

    /// The endpoint band a dragged stop has reached, or nil for the middle.
    static func removalEdge(offsetFromTop: Double, length: Double) -> RemovalEdge? {
        guard offsetFromTop.isFinite, length.isFinite, length > 0 else { return nil }
        if offsetFromTop <= removalBand * length { return .top }
        if offsetFromTop >= length - removalBand * length { return .bottom }
        return nil
    }

    /// The visible, one-based marker label.
    static func label(index: Int) -> String {
        "\(index + 1)"
    }
}

/// An interactive normalised manual-focus ruler: a yellow index over a fixed
/// tick rail, styled after `FocalLengthRuler`. It writes the raw lens position
/// directly, so the owning screen issues the single hardware write, and it
/// carries the same 44pt hit width and VoiceOver adjustable action as the other
/// camera controls.
///
/// On top of the focus scale it edits up to three session-only stops: a hold on
/// empty rail places one at the touched point, a hold on a marker then drags that
/// same marker, releasing a dragged marker at the top or bottom band removes it,
/// and a tap on a marker snaps focus back to its stored position. Holds and taps
/// never also drag the live focus, because the ordinary focus drag only reacts to
/// real movement and stands down once a hold has been recognised.
struct ManualFocusRuler: View {
    @Binding var lensPosition: Double
    let enabled: Bool
    /// Session-only stops. The default keeps every existing call site and the
    /// render harness valid; the owning screen passes its own `@State` array.
    @Binding var stops: [ManualFocusStop] = .constant([])

    /// The stop being edited by the current hold, or nil for an ordinary touch.
    @State private var editingStopID: UUID?
    /// True once a hold has been recognised, so the focus drag stands down.
    @State private var holdRecognized = false
    /// True when the finger has carried a dragged stop far enough to delete it.
    @State private var movedDuringEdit = false
    /// The endpoint band the dragged stop is currently over, if any.
    @State private var pendingRemoval: ManualFocusStopEdit.RemovalEdge?
    /// Where the current touch began, in the ruler's local space.
    @State private var pressLocation: CGPoint = .zero
    /// True once the ordinary drag has passed its movement threshold.
    @State private var focusDragMoved = false

    var body: some View {
        VStack(spacing: 4) {
            Text("MF")
                .font(NitrateTypography.font(size: 11))
                .foregroundStyle(.yellow)
            GeometryReader { geometry in
                let length = Double(geometry.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.45))
                    Canvas { context, size in
                        for tick in stride(from: 0.0, through: 1.0, by: 0.1) {
                            let y = size.height * tick
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: 6, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                        }
                        for tick in stride(from: 0.0, through: 1.0, by: 0.5) {
                            let y = size.height * tick
                            var path = Path()
                            path.move(to: CGPoint(x: size.width - 6, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                        }
                    }
                    deletionBands(in: geometry.size)
                    stopMarkers(in: geometry.size)
                    Rectangle()
                        .fill(.yellow)
                        .frame(width: geometry.size.width, height: 2)
                        .position(x: geometry.size.width / 2,
                                  y: ManualFocusRulerScale.indexFraction(lensPosition: lensPosition)
                                      * geometry.size.height)
                }
                .contentShape(Rectangle())
                .gesture(stopEditGesture(length: length))
                .simultaneousGesture(focusDragGesture(length: length))
                .accessibilityElement()
                .accessibilityLabel("Manual focus")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Adjusts the focus distance. Hold to place or move a stop, tap a stop to snap to it")
                .accessibilityAdjustableAction { direction in
                    guard enabled else { return }
                    let delta = direction == .increment ? ManualFocusRulerScale.step
                                                        : -ManualFocusRulerScale.step
                    lensPosition = ManualFocusRulerScale.adjusted(lensPosition: lensPosition, by: delta)
                }
                .accessibilityAction(named: "Add focus stop") { addStopAtCurrentFocus() }
                .accessibilityAction(named: "Snap to focus stop") { snapToNearestStop() }
                .accessibilityAction(named: "Remove focus stop") { removeNearestStop() }
                .accessibilityAction(named: "Move focus stop") {
                    moveNearestStop(by: ManualFocusRulerScale.step)
                }
            }
        }
        .frame(width: 44)
        .disabled(!enabled)
    }

    // MARK: - Marker rendering

    /// A thin orange line and its one-based label per stop, offset from the
    /// yellow index so a marker never hides the live focus line.
    @ViewBuilder private func stopMarkers(in size: CGSize) -> some View {
        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
            let y = CGFloat(ManualFocusRulerScale.indexFraction(lensPosition: stop.lensPosition)) * size.height
            let active = editingStopID == stop.id
            Rectangle()
                .fill(active ? SettingsControlChrome.lightPurple : SettingsControlChrome.halationOrange)
                .frame(width: size.width, height: 2)
                .opacity(0.9)
                .position(x: size.width / 2, y: y)
            Text(ManualFocusStopEdit.label(index: index))
                .font(NitrateTypography.font(size: 9))
                .foregroundStyle(SettingsControlChrome.halationOrange)
                .position(x: size.width - 8, y: y)
        }
    }

    /// The top and bottom release bands, shown only while a marker is being
    /// dragged so the removal affordance is never a permanent overlay.
    @ViewBuilder private func deletionBands(in size: CGSize) -> some View {
        if editingStopID != nil {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(SettingsControlChrome.halationOrange.opacity(0.28))
                    .frame(height: size.height * ManualFocusStopEdit.removalBand)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(SettingsControlChrome.halationOrange.opacity(0.28))
                    .frame(height: size.height * ManualFocusStopEdit.removalBand)
            }
            .allowsHitTesting(false)
        }
    }

    private var accessibilityValue: String {
        let percent = Int((ManualFocusRulerScale.clamped(lensPosition) * 100).rounded())
        let marker = stops.isEmpty ? "no focus stops" : "\(stops.count) focus stops"
        return "\(percent) percent, \(marker)"
    }

    // MARK: - Gestures

    /// A hold, then a drag, on the same touch: `.first(true)` places or grabs a
    /// stop, `.second(true, drag)` moves the one it grabbed. Sequenced so the
    /// drag keeps delivering after the hold is recognised.
    private func stopEditGesture(length: Double) -> some Gesture {
        LongPressGesture(minimumDuration: ManualFocusStopEdit.holdDuration,
                         maximumDistance: ManualFocusStopEdit.holdSlop)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard enabled else { return }
                switch value {
                case .first(true):
                    beginStopEdit(length: length)
                case .second(true, let drag?):
                    guard let id = editingStopID else { return }
                    moveStop(id: id, to: drag.location, length: length)
                default:
                    break
                }
            }
            .onEnded { value in
                guard enabled else { resetGestureState(); return }
                if case .second(true, let drag?) = value {
                    if let id = editingStopID {
                        moveStop(id: id, to: drag.location, length: length)
                    }
                }
                finishStopEdit()
            }
    }

    /// The ordinary focus drag. It only reacts to real finger travel, so resting
    /// to place a stop never drags the focus, and it stands down once the hold is
    /// recognised. A finished tap snaps to the nearest marker, or places focus at
    /// the touched point on empty rail exactly as the original ruler did.
    private func focusDragGesture(length: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard enabled, editingStopID == nil, !holdRecognized else { return }
                pressLocation = value.location
                guard distance(of: value.translation) >= ManualFocusStopEdit.focusDragThreshold else { return }
                focusDragMoved = true
                guard let position = ManualFocusRulerScale.lensPosition(
                    offsetFromTop: Double(value.location.y), length: length) else { return }
                lensPosition = position
            }
            .onEnded { value in
                defer { focusDragMoved = false }
                guard enabled, editingStopID == nil, !holdRecognized, !focusDragMoved else { return }
                if let target = snapTarget(at: value.location, length: length) {
                    lensPosition = target.lensPosition
                } else if let position = ManualFocusRulerScale.lensPosition(
                    offsetFromTop: Double(value.location.y), length: length) {
                    lensPosition = position
                }
            }
    }

    private func beginStopEdit(length: Double) {
        holdRecognized = true
        if let target = snapTarget(at: pressLocation, length: length) {
            editingStopID = target.id
            return
        }
        guard !ManualFocusStopEdit.isAtCapacity(stops) else { return }
        guard let position = ManualFocusRulerScale.lensPosition(
            offsetFromTop: Double(pressLocation.y), length: length) else { return }
        let updated = ManualFocusStopEdit.adding(stops, lensPosition: position)
        guard updated.count > stops.count else { return }
        stops = updated
        editingStopID = updated.last?.id
    }

    private func moveStop(id: UUID, to location: CGPoint, length: Double) {
        if distance(of: CGSize(width: location.x - pressLocation.x,
                               height: location.y - pressLocation.y)) >= ManualFocusStopEdit.focusDragThreshold {
            movedDuringEdit = true
        }
        pendingRemoval = movedDuringEdit
            ? ManualFocusStopEdit.removalEdge(offsetFromTop: Double(location.y), length: length)
            : nil
        guard let position = ManualFocusRulerScale.lensPosition(
            offsetFromTop: Double(location.y), length: length) else { return }
        stops = ManualFocusStopEdit.moving(stops, id: id, lensPosition: position)
        // Dragging a stop drives the live focus too, so the change is visible.
        lensPosition = position
    }

    private func finishStopEdit() {
        if let id = editingStopID, movedDuringEdit, pendingRemoval != nil {
            stops = ManualFocusStopEdit.removing(stops, id: id)
        }
        resetGestureState()
    }

    private func resetGestureState() {
        editingStopID = nil
        holdRecognized = false
        movedDuringEdit = false
        pendingRemoval = nil
        focusDragMoved = false
    }

    private func snapTarget(at location: CGPoint, length: Double) -> ManualFocusStop? {
        guard let position = ManualFocusRulerScale.lensPosition(
            offsetFromTop: Double(location.y), length: length) else { return nil }
        return ManualFocusStopEdit.snapTarget(stops,
                                              toLensPosition: position,
                                              tolerance: ManualFocusStopEdit.hitTolerance(length: length))
    }

    private func distance(of translation: CGSize) -> Double {
        Double((translation.width * translation.width + translation.height * translation.height).squareRoot())
    }

    // MARK: - Accessibility stop editing

    private func addStopAtCurrentFocus() {
        guard enabled else { return }
        stops = ManualFocusStopEdit.adding(stops, lensPosition: lensPosition)
    }

    private func snapToNearestStop() {
        guard enabled, let target = nearestStop() else { return }
        lensPosition = target.lensPosition
    }

    private func removeNearestStop() {
        guard enabled, let target = nearestStop() else { return }
        stops = ManualFocusStopEdit.removing(stops, id: target.id)
    }

    private func moveNearestStop(by delta: Double) {
        guard enabled, let target = nearestStop() else { return }
        stops = ManualFocusStopEdit.moving(stops, id: target.id, lensPosition: target.lensPosition + delta)
    }

    private func nearestStop() -> ManualFocusStop? {
        ManualFocusStopEdit.snapTarget(stops,
                                       toLensPosition: lensPosition,
                                       tolerance: .greatestFiniteMagnitude)
    }
}
