import SwiftUI

/// The classic REC cap on the minimal surfaces: a neutral light disc inside a
/// thin hairline ring, with a semantic red stop mark only while a take is live.
///
/// The machined body is gone — no gradient cap, rim, bevel or shadow — so the
/// control reads as a flat shutter against the preview and its state reads
/// through one colour change. Idle shows quiet dark REC lettering on the light
/// disc; an accepted tap replaces it with the red stop square immediately, so
/// startup stays visible and cancellable. Finalizing keeps the square but dims
/// it. The 84pt footprint, tap handling and press feedback are unchanged.
struct RecordPlungerFace: View {
    let presentation: RecordButtonPresentation
    var isPressed = false
    var rotationDegrees: Double = 0

    /// Unchanged footprint: the flat cap cannot resize the shutter row.
    private static let diameter: CGFloat = 84
    /// The approved study's neutral idle disc (#d6d4cf).
    private static let disc = Color(red: 0.84, green: 0.83, blue: 0.81)
    /// Hairline outer ring, neutral rather than a simulated metal rim.
    private static let ring = Color.white.opacity(0.62)
    /// The shared semantic recording red, matching the live status face and the
    /// modern REC face. Confirmed recording red is never recoloured by accent.
    private static let stopRed = Color(red: 0.95, green: 0.22, blue: 0.18)

    /// The same mark cancels startup, stops capture, and remains while draining.
    private var showsStopMark: Bool {
        presentation != .idle
    }

    /// Finalizing ignores taps, so the square reads as busy instead of live.
    private var isBusy: Bool {
        presentation == .stopping
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.disc)
                .padding(9)
            Circle()
                .strokeBorder(Self.ring, lineWidth: CameraControlBorder.lineWidth)
                .padding(3)
            glyph
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .offset(y: isPressed ? 1.5 : 0)
        .contentShape(Circle())
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        ZStack {
            if showsStopMark {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.stopRed)
                    .frame(width: 30, height: 30)
                    .opacity(isBusy ? 0.45 : 1)
            } else {
                Text("REC")
                    .font(NitrateTypography.font(size: 11))
                    .tracking(1)
                    .foregroundStyle(Color.black.opacity(0.62))
            }
        }
        .rotationEffect(.degrees(rotationDegrees))
    }
}

/// Gauge readout for the stock group: the number with `mm` beneath it, stacked
/// so neither is squeezed onto the other's baseline. No strip and no
/// perforations — the gauge is type, not a simulated film canister. The 28x28
/// slot keeps the existing stock-row geometry, and the whole stack rotates with
/// the face so it stays readable in landscape holds.
struct CameraGaugeLabel: View {
    let gauge: PrintGauge
    var rotationDegrees: Double = 0

    private var number: String {
        gauge.displayName.replacingOccurrences(of: "mm", with: "")
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(number)
                .font(NitrateTypography.font(size: 14))
                .foregroundStyle(.white.opacity(0.92))
            Text("mm")
                .font(NitrateTypography.font(size: 8))
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: 28, height: 28)
        .rotationEffect(.degrees(rotationDegrees))
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Print gauge, \(gauge.displayName)")
    }
}

/// The shipping duotone stock face, independent of the stock-picker interaction.
/// The identity stripes and the ISO lettering are preserved; the blurred
/// material rim behind the label is removed so the swatch stays flat.
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
                .font(NitrateTypography.font(size: 11))
                .tracking(0.5)
                .foregroundStyle(.white)
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
