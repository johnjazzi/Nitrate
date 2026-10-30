import SwiftUI

/// The inline Develop mode's centre control: a **Render** action, never a REC
/// button. It carries no capture behaviour of its own — the parent supplies the
/// action — so the Develop face cannot start, stop or cancel a recording.
///
/// The face is deliberately built from the classic REC plunger's vocabulary so
/// it reads as the same physical control at the same place: a dark shaded cap
/// with a filled disc and a short label. It keeps that plunger's 84pt footprint
/// exactly, so switching between Video and Develop cannot shift the bar's
/// layout, and its circular hit target is far above the 44pt minimum.
///
/// Enabled, the disc carries the app's orange accent with dark ink. Disabled,
/// the disc and ink are subdued to a neutral grey so the control reads as
/// unavailable while keeping every measured dimension.
struct DevelopShutterFace: View {
    /// Full-brightness accent disc when true; a subdued grey disc otherwise.
    var isEnabled = true
    /// A small, non-layout press response, mirroring the REC plunger's depression.
    var isPressed = false

    /// Shared with the REC plunger: the reserved footprint never changes.
    static let diameter: CGFloat = 84

    var body: some View {
        ZStack {
            // The dark shaded cap shared with the REC plunger, so both faces
            // occupy the identical visual and measured slot.
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(3)
            Circle()
                .fill(disc)
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.06),
                                                .black.opacity(0.65)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.5
                    )
                }
                .shadow(color: .black.opacity(isPressed ? 0.25 : 0.6),
                        radius: isPressed ? 1 : 3, x: 0, y: isPressed ? 1 : 4)
                .padding(8)
            glyph
        }
        .frame(width: Self.diameter, height: Self.diameter)
        // A guarded minimum keeps the circular hit target at least 44pt even if
        // the diameter constant is ever tuned down.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .offset(y: isPressed ? 1.5 : 0)
        .accessibilityHidden(true)
    }

    /// Orange accent when the action is available, neutral grey when it is not.
    /// The gradient keeps the same depth cue in both states.
    private var disc: LinearGradient {
        let colors: [Color] = isEnabled
            ? [Color(red: 0.97, green: 0.60, blue: 0.16),
               Color(red: 0.90, green: 0.48, blue: 0.07),
               Color(red: 0.62, green: 0.31, blue: 0.03)]
            : [Color(white: 0.40), Color(white: 0.32), Color(white: 0.24)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Icon and word label. Both are always present so enabling or disabling the
    /// control never reflows the face.
    private var glyph: some View {
        VStack(spacing: 2) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 21, weight: .semibold))
            Text("Render")
                .font(NitrateTypography.font(size: 12))
                .tracking(0.5)
        }
        .foregroundStyle(ink)
        .symbolRenderingMode(.monochrome)
    }

    /// Dark ink on the bright accent; a muted light ink on the subdued disc.
    private var ink: Color {
        isEnabled ? Color(white: 0.10) : .white.opacity(0.55)
    }
}
