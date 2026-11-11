import SwiftUI

/// The REC cap is red even at rest. Its stop mark acknowledges the accepted
/// tap immediately and allows cancellation while capture is starting.
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
                        if presentation != .idle {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(presentation == .stopping ? 0.4 : 0.9))
                                .frame(width: 15, height: 15)
                        } else {
                            Text("REC")
                                .font(NitrateTypography.font(size: 11))
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

/// A small vertical strip, not a literal perforation diagram. Width follows the
/// selected film gauge, not its inverse grain-size multiplier. Neutral is 35mm.
struct CameraGaugeLabel: View {
    let gauge: PrintGauge
    var rotationDegrees: Double = 0

    private var stripWidth: CGFloat {
        switch gauge {
        case .eightMillimetre: 12
        case .sixteenMillimetre: 16
        case .thirtyFiveMillimetre: 21
        case .seventyFiveMillimetre: 26
        }
    }

    var body: some View {
        Text(gauge.displayName)
            .font(NitrateTypography.font(size: 10))
            .foregroundStyle(.white.opacity(0.95))
            .fixedSize()
            .frame(width: 28, height: 28)
            .background {
                Path { path in
                    let left = (28 - stripWidth) / 2
                    path.addRoundedRect(in: CGRect(x: left, y: 0, width: stripWidth, height: 28),
                                        cornerSize: CGSize(width: 1, height: 1))
                    for y: CGFloat in [4, 21] {
                        path.addRect(CGRect(x: left, y: y, width: 1.5, height: 3))
                        path.addRect(CGRect(x: left + stripWidth - 1.5, y: y, width: 1.5, height: 3))
                    }
                }
                .fill(Color(red: 0.58, green: 0.34, blue: 0.16).opacity(0.75),
                      style: FillStyle(eoFill: true))
            }
            .rotationEffect(.degrees(rotationDegrees))
            .frame(width: 28, height: 28)
            .accessibilityLabel("Print gauge, \(gauge.displayName)")
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
                .font(NitrateTypography.font(size: 10))
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
