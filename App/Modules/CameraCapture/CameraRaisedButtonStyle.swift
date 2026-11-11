import SwiftUI

/// Shared borders for rectangular camera controls and recessed wells.
enum CameraControlBorder {
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 12
}

/// Fixed 44pt toolbar keys use an actual circle, including the hit region.
struct CameraRoundButtonStyle: ButtonStyle {
    var faceColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill((faceColor ?? .black).opacity(configuration.isPressed ? 0.7 : 0.45))
                    }
            }
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.38), .black.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: configuration.isPressed ? 1 : 3, y: 2)
            .contentShape(Circle())
    }
}

/// Shared tactile face for camera controls, styled after the machined panel of a
/// cinema camera: a soft-edged plate that is **translucent** rather than opaque,
/// so the preview reads through it and only the bevel, the rim and the shadow
/// define the control. A caller can still tint a control by supplying
/// `faceColor`; the tint is laid into the translucent face, not painted over it.
struct CameraRaisedButtonStyle: ButtonStyle {
    /// Tint mixed into the translucent face. Nil keeps it neutral.
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRaisedSurface(faceColor: faceColor, cornerRadius: cornerRadius,
                                          isPressed: configuration.isPressed))
    }
}

/// The translucent raised face itself.
struct CameraRaisedSurface: ViewModifier {
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var isPressed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(fill) }
            }
            .overlay {
                shape.strokeBorder(bevel, lineWidth: CameraControlBorder.lineWidth).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isPressed ? 0.16 : 0.38),
                    radius: isPressed ? 1 : 4,
                    x: 0,
                    y: isPressed ? 1 : 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .contentShape(shape)
    }

    /// Barely tinted: the material supplies the body, so the face stays see-through
    /// and the preview reads past the control.
    private var fill: Color {
        guard let faceColor else { return .black.opacity(isPressed ? 0.34 : 0.18) }
        return faceColor.opacity(isPressed ? 0.78 : 0.62)
    }

    /// Bright along the top edge, dark underneath — the raised bevel.
    private var bevel: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(isPressed ? 0.16 : 0.42),
                     .white.opacity(0.05),
                     .black.opacity(isPressed ? 0.50 : 0.42)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Recessed face with a dark top rim and a light bottom rim; no layout padding.
struct CameraInsetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CameraControlBorder.cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(Color.black.opacity(0.18)) }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.76), .black.opacity(0.20), .white.opacity(0.68)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: CameraControlBorder.lineWidth)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
    }
}

/// A translucent raised plate that groups related controls — the soft raised
/// area a machined camera panel forms around a cluster of buttons. See-through,
/// so it frames the group without hiding the preview behind it.
struct CameraControlWell: ViewModifier {
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var horizontalPadding: CGFloat = 6

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(Color.black.opacity(0.18)) }
            }
            .overlay {
                // The outer rim is inset: dark above, light below. The keys
                // inside retain their raised bevels.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.black.opacity(0.76), .black.opacity(0.20),
                                 .white.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: CameraControlBorder.lineWidth
                )

                .allowsHitTesting(false)
            }
            .contentShape(shape)
    }
}

extension View {
    /// Wrap a cluster of controls in the translucent raised plate.
    func cameraControlWell(cornerRadius: CGFloat = CameraControlBorder.cornerRadius, horizontalPadding: CGFloat = 6) -> some View {
        modifier(CameraControlWell(cornerRadius: cornerRadius, horizontalPadding: horizontalPadding))
    }
}
