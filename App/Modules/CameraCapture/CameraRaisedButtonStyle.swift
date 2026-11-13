import SwiftUI

/// Shared border tokens for the camera controls that still need a hairline.
/// The minimal surface pass removed every decorative rim, so `lineWidth` now
/// only names the one hairline the flat faces draw — the REC cap's outer ring.
enum CameraControlBorder {
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 12
}

/// Fixed 44pt toolbar keys use an actual circle, including the hit region.
/// Flat neutral fill: no material, rim gradient or shadow, so the preview is
/// the only body the key sits on.
struct CameraRoundButtonStyle: ButtonStyle {
    var faceColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(base(isPressed: configuration.isPressed))
                    .overlay { Circle().fill(tint(isPressed: configuration.isPressed)) }
            }
            .contentShape(Circle())
    }

    /// One dark neutral base for every key, so white glyphs stay legible over
    /// bright footage.
    private func base(isPressed: Bool) -> Color {
        .black.opacity(isPressed ? 0.66 : 0.5)
    }

    /// A selected key adds its accent as a restrained cast over the dark base —
    /// never a bright accent tile that would swallow the glyph.
    private func tint(isPressed: Bool) -> Color {
        (faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28)
    }
}

/// Shared face for rectangular camera controls. The visual weight comes from
/// one dark fill and a restrained pressed opacity — no translucent material,
/// bevel, rim or shadow. A caller can still tint a control by supplying
/// `faceColor`; the tint is a flat cast over the fill, not a layer over a
/// simulated plate.
struct CameraRaisedButtonStyle: ButtonStyle {
    /// Tint of the flat face. Nil keeps it neutral.
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRaisedSurface(faceColor: faceColor, cornerRadius: cornerRadius,
                                          isPressed: configuration.isPressed))
    }
}

/// The flat face itself.
struct CameraRaisedSurface: ViewModifier {
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var isPressed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(base)
                    .overlay { shape.fill(tint) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .contentShape(shape)
    }

    /// One dark neutral fill. Pressing deepens it slightly instead of moving a
    /// bevel, and keeps the caller's glyph readable on any accent.
    private var base: Color {
        .black.opacity(isPressed ? 0.66 : 0.5)
    }

    /// The accent cast for a selected/tinted control, kept restrained so it
    /// reads as a matching dark fill rather than an accent-coloured plate.
    private var tint: Color {
        (faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28)
    }
}

/// Flat recessed face for readouts; no top/bottom rim gradient, no material.
/// Layout padding stays with the caller, exactly as before.
struct CameraInsetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CameraControlBorder.cornerRadius, style: .continuous)
        content
            .background { shape.fill(Color.black.opacity(0.5)) }
            .contentShape(shape)
    }
}

/// A flat neutral plate that groups related controls. It keeps the existing
/// padding and hit region; only the simulated hardware — material, rims,
/// shadows — is gone.
struct CameraControlWell: ViewModifier {
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var horizontalPadding: CGFloat = 6

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background { shape.fill(Color.black.opacity(0.32)) }
            .contentShape(shape)
    }
}

extension View {
    /// Wrap a cluster of controls in the flat neutral plate.
    func cameraControlWell(cornerRadius: CGFloat = CameraControlBorder.cornerRadius, horizontalPadding: CGFloat = 6) -> some View {
        modifier(CameraControlWell(cornerRadius: cornerRadius, horizontalPadding: horizontalPadding))
    }
}
