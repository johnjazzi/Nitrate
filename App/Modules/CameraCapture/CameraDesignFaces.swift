import SwiftUI

/// The REC cap is red even at rest. Capture confirmation belongs to the lamp,
/// not to an optimistic color change on the button.
struct RecordPlungerFace: View {
    let presentation: RecordButtonPresentation
    var isPressed = false
    var rotationDegrees: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(3)
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.72, green: 0.39, blue: 0.38),
                             Color(red: 0.58, green: 0.26, blue: 0.26),
                             Color(red: 0.43, green: 0.18, blue: 0.19)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.06), .black.opacity(0.65)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1.5
                    )
                }
                .shadow(color: .black.opacity(isPressed ? 0.25 : 0.65),
                        radius: isPressed ? 1 : 3, x: 0, y: isPressed ? 1 : 4)
                .overlay {
                    Group {
                        if presentation == .recording || presentation == .stopping {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(presentation == .stopping ? 0.4 : 0.9))
                                .frame(width: 15, height: 15)
                        } else {
                            Text("REC")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .rotationEffect(.degrees(rotationDegrees))
                }
                .padding(8)
                .offset(y: isPressed ? 1.5 : -1)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Minimal gauge engraving beside the stock; no invented film-format icon.
struct CameraGaugeLabel: View {
    let text: String
    var rotationDegrees: Double = 0

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize()
            .rotationEffect(.degrees(rotationDegrees))
            .frame(width: 28, height: 28)
            .accessibilityLabel("Print gauge, \(text)")
    }
}

/// The shipping duotone stock face, independent of the stock-picker interaction.
struct CameraFilmStockFace: View {
    let primary: Color
    let secondary: Color
    let isoLight: String
    var faceSize: CGFloat = 44

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<5) { index in
                    (index == 0 || index == 1 || index == 4 ? primary : secondary)
                        .frame(height: faceSize / 5)
                }
            }
            Text(isoLight)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(width: faceSize * 1.15, height: faceSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Swap the unrotated proposal, then rotate the complete face and hit target.
/// The resulting visual bounds always equal the caller's reserved slot.
struct CameraRotatingSlot<Content: View>: View {
    var rotationDegrees: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let size = CameraControlGeometry.faceSize(in: geometry.size, degrees: rotationDegrees)
            content()
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
