import SwiftUI

/// Shared tactile face for camera controls, styled after the machined panel of a
/// cinema camera: a soft-edged plate that is **translucent** rather than opaque,
/// so the preview reads through it and only the bevel, the rim and the shadow
/// define the control. A caller can still tint a control by supplying
/// `faceColor`; the tint is laid into the translucent face, not painted over it.
struct CameraRaisedButtonStyle: ButtonStyle {
    /// Tint mixed into the translucent face. Nil keeps it neutral.
    var faceColor: Color?
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRaisedSurface(faceColor: faceColor, cornerRadius: cornerRadius,
                                          isPressed: configuration.isPressed))
    }
}

/// The translucent raised face itself.
struct CameraRaisedSurface: ViewModifier {
    var faceColor: Color?
    var cornerRadius: CGFloat = 8
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
                shape.strokeBorder(bevel, lineWidth: 1).allowsHitTesting(false)
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

/// A translucent raised plate that groups related controls — the soft raised
/// area a machined camera panel forms around a cluster of buttons. See-through,
/// so it frames the group without hiding the preview behind it.
struct CameraControlWell: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(Color.black.opacity(0.18)) }
            }
            .overlay {
                // A defined outer lip around the well; the individual key
                // bevels inside stay unchanged. Two concentric strokes give
                // the edge depth without making the plate opaque.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.68), .white.opacity(0.24),
                                 .black.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                shape.inset(by: 2).strokeBorder(
                    LinearGradient(
                        colors: [.black.opacity(0.42), .clear, .white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.48), radius: 9, x: 0, y: 4)
            .contentShape(shape)
    }
}

extension View {
    /// Wrap a cluster of controls in the translucent raised plate.
    func cameraControlWell(cornerRadius: CGFloat = 16) -> some View {
        modifier(CameraControlWell(cornerRadius: cornerRadius))
    }
}
