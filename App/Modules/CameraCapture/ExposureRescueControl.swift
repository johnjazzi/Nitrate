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

/// The compact "too bright" affordance. Shown above the live EV column only when
/// `DaylightExposureRescuePolicy.shouldOffer` is true (or the mode is already
/// armed). Minimum 44pt height, 92pt wide. The face is unrotated: the parent turns
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

/// The rescue confirmation. Normal mode offers the 60 fps switch; armed mode offers
/// the return to 24 fps, so the active badge stays tappable even after the meter
/// drops back below the threshold. Fixed, short content — no `ScrollView`, so it
/// cannot be trapped by a scroll that never fits. No orientation modifier: it is a
/// plain centred SwiftUI panel.
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
        VStack(alignment: .leading, spacing: 12) {
            Text(armed ? "Daylight 60 fps is on" : "Rescue a too-bright scene")
                .font(.headline)
                .foregroundStyle(.white)

            Text("60 fps drops the fixed shutter to 1/120 — about 1.3 stops less light. "
                 + "Motion looks less cinematic than 24 fps. For a locked-off bright scene "
                 + "an ND filter is still the better tool.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
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

            HStack(spacing: 10) {
                Button(armed ? "Keep 60 fps" : "Keep 24 fps", action: onCancel)
                    .buttonStyle(CameraRaisedButtonStyle())
                Button(armed ? "Return to 24 fps" : "Use 60 fps") { onSelect(!armed) }
                    .buttonStyle(CameraRaisedButtonStyle(faceColor: canConfirm ? .orange : nil))
                    .disabled(!canConfirm)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: 340)
        .modifier(CameraRaisedSurface(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }
}