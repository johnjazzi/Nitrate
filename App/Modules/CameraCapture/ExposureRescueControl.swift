import CoreGraphics
import SwiftUI

/// Platform-agnostic policy for the daylight exposure-rescue affordance.
///
/// The rescue button appears only when the live meter reads at least two stops
/// brighter than the selected exposure target — the manual ISO target (`0`) or the
/// live auto-exposure bias, matching the expression the EV indicator uses. It is a
/// plain signed difference: no absolute value and no clamping, so an under-exposed
/// or matched scene can never arm it. The active 60 fps badge is not gated here;
/// the parent keeps it reachable below the threshold so the mode can be turned off.
enum DaylightExposureRescuePolicy {
    /// Stops over target before the affordance is offered.
    static let thresholdStops: Float = 2

    static func shouldOffer(meteredEV: Float, targetEV: Float, isAvailable: Bool) -> Bool {
        guard isAvailable, meteredEV.isFinite, targetEV.isFinite else { return false }
        let difference = meteredEV - targetEV
        return difference.isFinite && difference >= thresholdStops
    }

    /// Whether the modal's confirm action may run: the mode must be available on
    /// the device **and** no take/lens/mode transition may be in flight.
    static func canConfirm(available: Bool, canChange: Bool) -> Bool {
        available && canChange
    }
}

/// Pure placement for the rescue button. The button is a full-canvas sibling in
/// `ContentView`, never a child of `CameraShootingLayout`, so it cannot enlarge the
/// control bar's measured footprint. Its slot reserves the **rotated** bounds of a
/// 92×44 face (44×92 once held in landscape) and always sits 6pt above the
/// measured exposure column in the portrait canvas — the same anchor as the EV
/// meter, so a physical hold never moves it over the top bar or the preview.
///
/// When the caller passes the manual controls' reserved rectangle as `excluding`,
/// the slot must never intersect them. The preference order is: keep the plain
/// above-the-column anchor if it already clears them; otherwise sit **above-left**
/// of the manual controls (both edges clear by `gapBesideControls`); otherwise a
/// **left offset** beside them at the exposure anchor; otherwise rise **above**
/// them with the offset the canvas allows. It returns nil only when no candidate
/// stays inside the viewport while clearing the exclusion.
enum DaylightExposureRescueGeometry {
    static let buttonWidth: CGFloat = 92
    static let buttonHeight: CGFloat = 44
    static let gapAboveExposure: CGFloat = 6
    /// Clearance kept between the slot and the manual controls it must avoid.
    static let gapBesideControls: CGFloat = 6

    /// Reserved bounds for the button above `exposure` (both in the shared
    /// `cameraCanvas` space), clamped horizontally inside `viewport`, or nil when
    /// the slot would leave the top of the viewport — the caller then hides the
    /// affordance rather than letting it overlap the top toolbar. The face itself
    /// is unchanged; only the reserved frame turns for a quarter-turn hold.
    ///
    /// `excluding` is the manual controls' reserved rectangle in the same space.
    /// It defaults to nil and then the result is exactly the historical single
    /// anchor: centred above the exposure column, 6pt clear of its top edge.
    static func buttonRect(above exposure: CGRect, in viewport: CGSize,
                           rotationDegrees: Double = 0,
                           excluding manualControls: CGRect? = nil) -> CGRect? {
        let isQuarterTurn = abs(rotationDegrees.truncatingRemainder(dividingBy: 180)) == 90
        let width = isQuarterTurn ? buttonHeight : buttonWidth
        let height = isQuarterTurn ? buttonWidth : buttonHeight
        guard viewport.width >= width, viewport.height >= height else { return nil }
        let anchorY = exposure.minY - gapAboveExposure - height
        guard anchorY >= 0 else { return nil }
        let centeredX = clampedHorizontal(exposure.midX - width / 2, width: width, in: viewport)

        // No exclusion to steer around: the original anchor, unchanged.
        guard let manual = manualControls,
              manual.width > 0, manual.height > 0,
              manual.minX.isFinite, manual.minY.isFinite,
              manual.maxX.isFinite, manual.maxY.isFinite else {
            return CGRect(x: centeredX, y: anchorY, width: width, height: height)
        }

        // A slot at the plain anchor that already clears the controls is kept.
        let anchored = CGRect(x: centeredX, y: anchorY, width: width, height: height)
        if !anchored.intersects(manual) { return anchored }

        let gap = gapBesideControls
        // The top edge and left edge the slot must clear to sit above-left.
        let aboveY = manual.minY - gap - height
        let leftX = manual.minX - gap - width

        // Preferred: above-left of the manual controls, still above the column.
        if leftX >= 0, leftX <= viewport.width - width, aboveY >= 0, aboveY <= anchorY {
            return CGRect(x: leftX, y: aboveY, width: width, height: height)
        }
        // Otherwise a left offset beside them, keeping the exposure anchor.
        if leftX >= 0, leftX <= viewport.width - width {
            return CGRect(x: leftX, y: anchorY, width: width, height: height)
        }
        // Otherwise rise above them, offset as far left as the canvas allows.
        if aboveY >= 0, aboveY <= anchorY {
            return CGRect(x: centeredX, y: aboveY, width: width, height: height)
        }
        return nil
    }

    /// Clamp a horizontal origin so a `width`-wide slot stays inside `viewport`.
    private static func clampedHorizontal(_ x: CGFloat, width: CGFloat, in viewport: CGSize) -> CGFloat {
        min(max(x, 0), viewport.width - width)
    }
}

/// Pure placement for the idle-only armed 60 fps badge. When the rescue trigger
/// is gone (the meter dropped back below the threshold) an armed session must
/// still have a visible way back to 24 fps. The badge mirrors the mood timer's
/// placement rules exactly: on the physical top edge in a quarter-turn hold,
/// otherwise floating centred in the stationary toolbar row. It is a full-canvas
/// sibling — never a toolbar slot — so it reserves no toolbar height, never hides
/// the lens key and cannot resize the framed preview.
enum DaylightIdleBadgeGeometry {
    static let badgeSize = CGSize(width: 112, height: 40)

    /// Reserved bounds for the badge in the shared `cameraCanvas` space, or nil
    /// when the canvas cannot hold it (the caller then omits the badge rather
    /// than drawing it over the preview or off-screen).
    static func rect(viewport: CGSize, toolbarBottom: CGFloat, controlsTop: CGFloat,
                     rotationDegrees: Double) -> CGRect? {
        guard viewport.width >= badgeSize.width, viewport.height >= badgeSize.height else { return nil }
        if abs(rotationDegrees.truncatingRemainder(dividingBy: 180)) == 90 {
            // Physical top edge, the same anchor the live timer floats on.
            guard let edge = RecordingStatusOverlayGeometry.rect(
                viewport: viewport, toolbarBottom: toolbarBottom, controlsTop: controlsTop,
                rotationDegrees: rotationDegrees) else { return nil }
            return CGRect(x: edge.midX - badgeSize.width / 2, y: edge.midY - badgeSize.height / 2,
                          width: badgeSize.width, height: badgeSize.height)
        }
        // Portrait: the face is the self-rotating status face, so the slot is
        // recorded upright and centred in the stationary toolbar row.
        guard toolbarBottom >= badgeSize.height else { return nil }
        return CGRect(x: (viewport.width - badgeSize.width) / 2,
                      y: toolbarBottom - badgeSize.height - 5,
                      width: badgeSize.width, height: badgeSize.height)
    }
}

/// The compact "too bright" affordance. Shown above the live EV column only when
/// `DaylightExposureRescuePolicy.shouldOffer` is true. Active mode management
/// below that threshold uses the status badge. Minimum 44pt height, 92pt wide.
/// The face is unrotated: the parent turns
/// the whole control with `.rotationEffect` and reserves the bounds from
/// `DaylightExposureRescueGeometry`, so this view must not also turn it.
struct ExposureRescueButton: View {
    /// True while the session-only 60 fps mode is active; the face then reads as a
    /// badge that reopens the modal to return to 24 fps.
    var armed: Bool
    /// False while a take, lens change or mode transition blocks a switch; the
    /// face dims and stops accepting taps but stays visible.
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: armed ? "bolt.fill" : "sun.max.fill")
                    .font(NitrateTypography.font(size: 13))
                Text(armed ? "60 fps" : "Too bright?")
                    .font(NitrateTypography.font(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(armed ? Color.orange : .white)
            .frame(width: DaylightExposureRescueGeometry.buttonWidth,
                   height: DaylightExposureRescueGeometry.buttonHeight)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: armed ? .orange : nil))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(armed ? "Daylight 60 fps active" : "Daylight exposure rescue")
        .accessibilityHint(armed ? "Opens options to return to 24 fps"
                                 : "Opens options to rescue an over-bright scene")
    }
}

/// Pure gates for the two non-frame-rate rescue options. Both read the owners
/// that already exist — the push/pull ladder and the lens aperture capability —
/// and neither invents a value: a pull is always a real rung on the ladder, and
/// an aperture target is always a stop the active lens reports.
///
/// The offer begins at two stops over target. Pull jumps two rungs towards the
/// ladder floor; aperture selects the largest reported f-number in one tap.
/// Each remains an explicit, independent choice.
enum DaylightRescuePullPolicy {
    /// Two rungs darker than `stops`, clamped to the ladder floor, or nil when
    /// the ladder is already at or below that floor. `floor` is the owner's own
    /// minimum (`PushPullStops`) and must itself be negative: a non-negative
    /// request is a broken floor, not an offer, so no destination is invented
    /// from it.
    ///
    /// The destination is a real pull even from a pushed or neutral take. Stops
    /// are signed and the ladder runs -3...+2, so the jump is `min(stops, 0) - 2`
    /// clamped to the floor: PUSH +2, PUSH +1 and neutral 0 all develop at -2
    /// (the two-stop pull the ≥2 EV trigger implies), an existing -1 goes to -3,
    /// and an existing -2 also lands on -3 rather than overshooting the ladder.
    /// A negative `stops` therefore can never move brighter.
    static func nextStops(after stops: Int, floor: Int) -> Int? {
        guard floor < 0, stops > floor else { return nil }
        return max(min(stops, 0) - 2, floor)
    }

    /// Concise row title for a destination rung, stated as a magnitude: a
    /// destination of -2 reads "Pull 2 stops", never "Pull -2 stops".
    static func title(forStops stops: Int) -> String {
        let magnitude = abs(stops)
        return "Pull \(magnitude) stop\(magnitude == 1 ? "" : "s")"
    }
}

/// Aperture rescue targets the **strongest** f-number the active
/// variable-aperture lens reports — not the next rung up. On a lens whose
/// ladder tops out at f/4 this is f/4; on a lens that stops at f/2.8 it is
/// f/2.8. The destination is never guessed: when the current iris is unknown, or
/// no supported stop is above it, no destination exists and the option is not
/// offered — no invented close to an f/4 the hardware does not report, and no
/// offer on fixed-aperture or front/tele lenses (their capability reports a
/// single stop or none, both of which leave nothing above the current iris).
enum DaylightRescueAperturePolicy {
    /// The largest finite, positive reported stop above `current`, or nil. The
    /// lens' own list is used as given: unsorted ladders pick the true maximum,
    /// and non-finite or non-positive entries can never become a destination.
    static func strongestStop(after current: Float?, stops: [Float]) -> Float? {
        guard let current, current.isFinite, current > 0 else { return nil }
        return stops.filter { $0.isFinite && $0 > 0 && $0 > current + 0.001 }.max()
    }

    /// Row title in the same f-number form the lens reports: a whole stop reads
    /// "Stop down to f/4", a third-stop lens reads "Stop down to f/2.8".
    static func title(forStop stop: Float) -> String {
        let number = stop == stop.rounded()
            ? String(format: "%.0f", stop)
            : String(format: "%.1f", stop)
        return "Stop down to f/" + number
    }
}

/// One compact row on the rescue card. `enabled == false` keeps the row visible
/// with a one-line reason, so an unavailable option is explained rather than
/// silently hidden — the meter may be overexposed while a take is draining.
struct DaylightRescueOption: Equatable {
    var title: String
    var detail: String
    var enabled: Bool
}

/// Builds the three option rows from the existing owners' facts. Pure, so the
/// gating (which option is offered, and why one is refused) is regression-testable
/// without a camera: the frame-rate row never gates the other two, and an absent
/// aperture rung removes only the aperture row.
enum DaylightRescuePresentation {
    /// Frame-rate row. `available` is the device's 60 fps capability; `canChange`
    /// is the live session's transition gate. Unavailable stays visible and
    /// refused rather than disappearing, because the card is the only place the
    /// operator learns why.
    ///
    /// Capability only gates *entering* 60 fps. Returning to 24 is always
    /// possible on a session that is already armed, even if the capability read
    /// has since gone false (a lens or format change), so an armed session is
    /// never stranded in 60 fps. The `canChange` busy gate still wins on both legs.
    static func sixty(armed: Bool, available: Bool, canChange: Bool) -> DaylightRescueOption {
        if armed {
            guard canChange else {
                return DaylightRescueOption(title: "Return to 24 fps",
                                            detail: "Busy — finish the take first", enabled: false)
            }
            return DaylightRescueOption(title: "Return to 24 fps",
                                        detail: "Session-only mode off", enabled: true)
        }
        if !available {
            return DaylightRescueOption(title: "60 fps", detail: "Not available on this camera",
                                        enabled: false)
        }
        guard canChange else {
            return DaylightRescueOption(title: "Use 60 fps", detail: "Busy — finish the take first",
                                        enabled: false)
        }
        return DaylightRescueOption(title: "Use 60 fps", detail: "1/120 shutter · this session",
                                    enabled: true)
    }

    /// Push/pull row. Development only: the take is already recorded, so the row
    /// never claims it reduces incoming light or recovers clipped highlights.
    /// The title names the whole destination in one tap ("Pull 2 stops"), so the
    /// operator sees the leap before taking it.
    static func pull(stockSelected: Bool, currentStops: Int?, floor: Int, busy: Bool) -> DaylightRescueOption {
        let current = currentStops ?? 0
        let next = DaylightRescuePullPolicy.nextStops(after: current, floor: floor)
        let title = next.map(DaylightRescuePullPolicy.title(forStops:)) ?? "Maximum pull"
        let detail = stockSelected ? "Develops darker · not a capture change" : "Select a stock first"
        guard stockSelected, next != nil else {
            return DaylightRescueOption(title: title, detail: detail, enabled: false)
        }
        if busy {
            return DaylightRescueOption(title: title, detail: "Busy — finish the take first",
                                        enabled: false)
        }
        return DaylightRescueOption(title: title, detail: detail, enabled: true)
    }

    /// Aperture row, or nil when the active lens reports no stop above the
    /// current iris. `nextStop` is the strongest supported destination from
    /// `DaylightRescueAperturePolicy.strongestStop(after:stops:)`. The canonical
    /// `setLensAperture` guard still owns the final refusal; the row is
    /// pre-disabled while the device is busy.
    static func aperture(nextStop: Float?, enabled: Bool) -> DaylightRescueOption? {
        guard let nextStop else { return nil }
        return DaylightRescueOption(title: DaylightRescueAperturePolicy.title(forStop: nextStop),
                                    detail: enabled ? "Strongest stop · applies to the next take"
                                                    : "Busy — finish the take first",
                                    enabled: enabled)
    }
}

/// The rescue options card. Fixed, short content — no `ScrollView` and no
/// editorial prose: each row states the action, the destination amount and, when
/// refused, the one reason. Long-form explanation lives in Settings → About.
///
/// It is rendered by `DaylightExposureRescueOverlay`, which dims the camera canvas
/// behind it: this is an in-camera choice, not a page. The card reuses the same
/// translucent face as the rest of the chrome so the preview still reads through,
/// and its rows are deliberately taller than the toolbar keys because they are
/// tapped while watching a bright scene.
struct DaylightExposureRescueModal: View {
    /// True while the session-only 60 fps mode is active.
    var armed: Bool
    var sixty: DaylightRescueOption
    /// Nil when no stock is selected, or the ladder is already at its floor.
    var pull: DaylightRescueOption
    /// Nil when the active lens reports no higher supported f-number.
    var aperture: DaylightRescueOption?
    /// `true` arms 60 fps, `false` returns to 24 fps.
    var onSixty: (Bool) -> Void
    var onPull: () -> Void
    var onAperture: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(armed ? "Too bright · 60 fps on" : "Too bright?")
                .font(NitrateTypography.font(size: 18))
                .foregroundStyle(.white)

            optionRow(sixty, tint: armed ? .orange : nil, action: { onSixty(!armed) })
            optionRow(pull, tint: nil, action: onPull)
            if let aperture {
                optionRow(aperture, tint: nil, action: onAperture)
            }

            Button(action: onCancel) {
                Text(armed ? "Keep 60 fps" : "Cancel")
                    .font(NitrateTypography.font(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 360)
        .background(cardFace)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    /// Readable over a dimmed preview: the shared material, plus one extra dark
    /// layer, because this card carries a warning that must stay legible.
    private var cardFace: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            }
    }

    /// One action row: the label, the destination amount, and any refusal reason
    /// on a second line. 50pt minimum height, wider than a 44pt toolbar key.
    private func optionRow(_ option: DaylightRescueOption, tint: Color?,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(NitrateTypography.font(size: 15))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(option.detail)
                    .font(NitrateTypography.font(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(0.72)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: tint, cornerRadius: 12))
        .disabled(!option.enabled)
        .opacity(option.enabled ? 1 : 0.5)
    }
}

/// The rescue card as it appears in the camera: a dim scrim over the live canvas
/// with the card floating in the middle.
///
/// This is an overlay on the camera canvas rather than a system sheet, so the
/// framed preview and the shooting bar are never re-laid-out and the user keeps
/// seeing the scene they are metering while they decide. Tapping outside the card
/// dismisses it without changing anything, the same outcome as cancel.
struct DaylightExposureRescueOverlay: View {
    var armed: Bool
    var sixty: DaylightRescueOption
    var pull: DaylightRescueOption
    var aperture: DaylightRescueOption?
    var onSixty: (Bool) -> Void
    var onPull: () -> Void
    var onAperture: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            DaylightExposureRescueModal(armed: armed, sixty: sixty, pull: pull, aperture: aperture,
                                        onSixty: onSixty, onPull: onPull, onAperture: onAperture,
                                        onCancel: onCancel)
                .padding(.horizontal, 28)
        }
        .transition(.opacity)
    }
}