#if os(iOS)
import SwiftUI

/// The push/pull control, shared by the stock sheet and the Develop panel.
///
/// Closed, the pill reads the effective stops as a single word — PUSH, PULL or
/// 0 — so the state is legible without opening it, and auto and a manual 0 never
/// look alike. Tapping it opens the full ladder plus Auto; there is no separate
/// toggle. Auto is a state, not a stop: the manual rung is left as dialled, so
/// switching back to a hand choice in the same session restores it.
///
/// The caller owns the persisted preference and the resolved exposure, so the
/// camera sheet and Develop read and write the same remembered value.
struct PushPullControl: View {
    /// The exposure this render will apply.
    let resolved: PushPullExposure
    @Binding var isAutomatic: Bool
    @Binding var manualStops: PushPullStops
    /// Called after any change so the caller can persist the preference.
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            Button { chooseAutomatic() } label: {
                if isAutomatic {
                    Label("Auto from the meter", systemImage: "checkmark")
                } else {
                    Text("Auto from the meter")
                }
            }
            Divider()
            ForEach(PushPullStops.allCases) { stops in
                Button { chooseManual(stops) } label: {
                    if !isAutomatic && manualStops == stops {
                        Label(stops.displayName, systemImage: "checkmark")
                    } else {
                        Text(stops.displayName)
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                // The word is the label above the control; the amount is what the
                // operator reads at a glance, so it goes in the pill itself.
                Text(resolved.stops.effectWord)
                    .font(NitrateTypography.font(.caption2))
                    .fontWeight(.semibold)
                    .kerning(0.5)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(resolved.stops.displayName)
                    .font(NitrateTypography.font(.caption2).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(tint.opacity(0.16)))
                    .overlay { Capsule().stroke(tint.opacity(0.6), lineWidth: 1) }
                    .contentShape(Capsule())
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("stock.pushPull")
        .accessibilityLabel("Push or pull")
        .accessibilityValue(accessibilityValue)
    }

    private var tint: Color {
        let stops = resolved.stops.stops
        if stops > 0 { return .orange }
        if stops < 0 { return .blue }
        return .secondary
    }

    private var accessibilityValue: String {
        let effect = resolved.isNeutral
            ? "normal"
            : "\(resolved.stops.effectName) \(abs(resolved.stops.stops)) stops"
        return isAutomatic
            ? "\(resolved.stops.effectWord), \(effect) from the meter"
            : "\(resolved.stops.effectWord), \(effect) chosen by hand"
    }

    private func chooseAutomatic() {
        withAnimation(.easeOut(duration: 0.15)) { isAutomatic = true }
        onChange()
    }

    private func chooseManual(_ stops: PushPullStops) {
        withAnimation(.easeOut(duration: 0.15)) {
            isAutomatic = false
            manualStops = stops
        }
        onChange()
    }
}
#endif
