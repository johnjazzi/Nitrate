import SwiftUI

/// Fixed geometry and the shared inset rim for the compact settings controls.
///
/// The rim reuses the app's inset-surface language (dark upper edge, light lower
/// edge, no raised drop shadow) so a settings well reads as recessed like the
/// camera's own wells. The values are local to Purchase rather than reusing
/// `CameraInsetSurface`, whose fixed 12pt radius is too round for a 54x32 switch.
enum SettingsControlChrome {
    static let wellWidth: CGFloat = 54
    static let wellHeight: CGFloat = 32
    static let wellRadius: CGFloat = 9
    static let thumbSide: CGFloat = 24
    static let thumbRadius: CGFloat = 5
    static let halationOrange = Color(red: 0.95, green: 0.45, blue: 0.12)
    static let lightPurple = Color(red: 0.78, green: 0.70, blue: 0.95)

    static let rim = LinearGradient(
        colors: [.black.opacity(0.70), .black.opacity(0.20), .white.opacity(0.55)],
        startPoint: .top,
        endPoint: .bottom
    )

    static var wellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
    }
}

/// The leading icon-and-label of a settings row. The icon is decorative — the
/// label carries the accessible name — and the label wraps instead of
/// truncating, so a long title survives Dynamic Type instead of clipping.
struct SettingsRowLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(NitrateTypography.font(.body))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The compact selected-value chip: the current choice beside a chevron, in the
/// same grayscale inset well as the switch. Sized to its short value text but
/// padded to a >=44pt hit target so it is never a tiny tappable cap.
struct SettingsValueLabel: View {
    let valueText: String

    var body: some View {
        HStack(spacing: 4) {
            Text(valueText)
                .font(NitrateTypography.font(.subheadline))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(NitrateTypography.font(.caption2).weight(.semibold))
        }
        .foregroundStyle(SettingsControlChrome.lightPurple)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            SettingsControlChrome.wellShape
                .fill(.ultraThinMaterial)
                .overlay { SettingsControlChrome.wellShape.fill(Color.black.opacity(0.20)) }
        }
        .overlay {
            SettingsControlChrome.wellShape
                .strokeBorder(SettingsControlChrome.rim, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The trailing control for an enumerated settings choice: a menu whose button
/// shows the current value with a chevron, and whose native picker lists every
/// choice with a check mark on the selected one. The picker itself stays at the
/// call site, so the row keeps one explicit `Picker` per setting.
struct SettingsSelectionRow<Choices: View>: View {
    let title: String
    let valueText: String
    @ViewBuilder var choices: () -> Choices

    var body: some View {
        Menu {
            choices()
        } label: {
            SettingsValueLabel(valueText: valueText)
        }
        .tint(SettingsControlChrome.lightPurple)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
}

/// A native `Toggle` wearing the app's compact switch face: a rectangular
/// recessed well with a small rounded-square thumb. The switch keeps its native
/// switch role, its on/off value and its label through an accessibility
/// representation, keeps a >=44pt hit target, and holds still under Reduce
/// Motion (no position animation).
struct SettingsToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            track(isOn: configuration.isOn)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The custom face is a Button, so restore the real switch semantics:
        // role, on/off value and label come from a native Toggle.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }

    private func track(isOn: Bool) -> some View {
        SettingsControlChrome.wellShape
            .fill(.ultraThinMaterial)
            .overlay { SettingsControlChrome.wellShape.fill(Color.black.opacity(isOn ? 0.10 : 0.26)) }
            .overlay {
                SettingsControlChrome.wellShape
                    .strokeBorder(SettingsControlChrome.rim, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: SettingsControlChrome.thumbRadius, style: .continuous)
                    .fill(isOn ? SettingsControlChrome.halationOrange : Color.white.opacity(0.60))
                    .frame(width: SettingsControlChrome.thumbSide, height: SettingsControlChrome.thumbSide)
                    .padding(4)
            }
            .frame(width: SettingsControlChrome.wellWidth, height: SettingsControlChrome.wellHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOn)
    }
}
