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
enum DaylightExposureRescueGeometry {
    static let buttonWidth: CGFloat = 92
    static let buttonHeight: CGFloat = 44
    static let gapAboveExposure: CGFloat = 6

    /// Reserved bounds for the button above `exposure` (both in the shared
    /// `cameraCanvas` space), clamped horizontally inside `viewport`, or nil when
    /// the slot would leave the top of the viewport — the caller then hides the
    /// affordance rather than letting it overlap the top toolbar. The face itself
    /// is unchanged; only the reserved frame turns for a quarter-turn hold.
    static func buttonRect(above exposure: CGRect, in viewport: CGSize,
                           rotationDegrees: Double = 0) -> CGRect? {
        let isQuarterTurn = abs(rotationDegrees.truncatingRemainder(dividingBy: 180)) == 90
        let width = isQuarterTurn ? buttonHeight : buttonWidth
        let height = isQuarterTurn ? buttonWidth : buttonHeight
        guard viewport.width >= width, viewport.height >= height else { return nil }
        let y = exposure.minY - gapAboveExposure - height
        guard y >= 0 else { return nil }
        let x = min(max(exposure.midX - width / 2, 0), viewport.width - width)
        return CGRect(x: x, y: y, width: width, height: height)
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
                    .font(.system(size: 13, weight: .semibold))
                Text(armed ? "60 fps" : "Too bright?")
                    .font(.system(size: 11, weight: .semibold))
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

/// The rescue confirmation card. Normal mode offers the 60 fps switch; armed mode
/// offers the return to 24 fps, so the active badge stays tappable even after the
/// meter drops back below the threshold. Fixed, short content — no `ScrollView`,
/// so it cannot be trapped by a scroll that never fits.
///
/// It is rendered by `DaylightExposureRescueOverlay`, which dims the camera canvas
/// behind it: this is an in-camera confirmation, not a page. The card reuses the
/// same translucent face as the rest of the chrome so the preview still reads
/// through, and its actions are deliberately wider and taller than the toolbar
/// keys because they are read and tapped while watching a bright scene.
struct DaylightExposureRescueModal: View {
    /// True while the session-only 60 fps mode is active.
    var armed: Bool
    /// False when the active device has no eligible 4K Apple Log 60 fps format.
    var available: Bool
    /// False while a take, lens change or mode transition blocks a switch.
    var canChange: Bool
    /// Confirm: `true` switches to 60 fps, `false` returns to 24 fps.
    var onSelect: (Bool) -> Void
    /// Dismiss without changing the mode.
    var onCancel: () -> Void

    private var canConfirm: Bool {
        DaylightExposureRescuePolicy.canConfirm(available: available, canChange: canChange)
    }

    private var blockedReason: String? {
        if !available {
            return "This device has no eligible 4K Apple Log 60 fps format. The mode stays unavailable."
        }
        if !canChange {
            return "Finish the current take, lens change or mode transition before switching frame rate."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(armed ? "Daylight 60 fps is on" : "24 fps or 60 fps?")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)

            if !armed {
                Text("Films are shot at 24 fps (except The Hobbit, but we don't count that). "
                     + "Over 100 years ago we found a perfect balance: 24 fps with a 180° shutter, "
                     + "just enough blur to feel real and present.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("But this is an iPhone, and modern tech has given us highly sensitive sensors. "
                 + "This mode sets 60 fps and drops the shutter to 1/120 — about 1.3 stops less light — "
                 + "giving you the ability to shoot in daylight. An ND filter is the better answer "
                 + "if you can use one.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Text("Session-only: it reverts to 24 fps when the camera session ends and is never saved.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            if let blockedReason {
                Text(blockedReason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                actionButton(armed ? "Keep 60 fps" : "Keep 24 fps", tint: nil, enabled: true,
                             action: onCancel)
                actionButton(armed ? "Return to 24 fps" : "Use 60 fps",
                             tint: canConfirm ? .orange : nil, enabled: canConfirm,
                             action: { onSelect(!armed) })
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
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

    /// Deliberately larger than a 44pt toolbar key: wide horizontal padding so the
    /// label is never crowded by the bevel, and a 52pt minimum height.
    private func actionButton(_ title: String, tint: Color?, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: tint, cornerRadius: 12))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The rescue confirmation as it appears in the camera: a dim scrim over the live
/// canvas with the card floating in the middle.
///
/// This is an overlay on the camera canvas rather than a system sheet, so the
/// framed preview and the shooting bar are never re-laid-out and the user keeps
/// seeing the scene they are metering while they decide. Tapping outside the card
/// dismisses it without changing the mode, which is the same outcome as the
/// cancel action.
struct DaylightExposureRescueOverlay: View {
    var armed: Bool
    var available: Bool
    var canChange: Bool
    var onSelect: (Bool) -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            DaylightExposureRescueModal(armed: armed, available: available, canChange: canChange,
                                        onSelect: onSelect, onCancel: onCancel)
                .padding(.horizontal, 28)
        }
        .transition(.opacity)
    }
}