import SwiftUI

/// Shared tactile face for camera controls. A caller can retain a selected
/// control's established color by supplying it as `faceColor`.
struct CameraRaisedButtonStyle: ButtonStyle {
    var faceColor: Color = Color(red: 0.16, green: 0.17, blue: 0.19)
    var cornerRadius: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRaisedSurface(faceColor: faceColor, cornerRadius: cornerRadius,
                                          isPressed: configuration.isPressed))
    }
}

struct CameraRaisedSurface: ViewModifier {
    var faceColor: Color = Color(red: 0.16, green: 0.17, blue: 0.19)
    var cornerRadius: CGFloat = 8
    var isPressed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background { shape.fill(faceColor) }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.34), .white.opacity(0.08), .black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isPressed ? 0.12 : 0.42),
                    radius: isPressed ? 1 : 3,
                    x: 0,
                    y: isPressed ? 1 : 3)
            .offset(y: isPressed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .contentShape(shape)
    }
}
