import SwiftUI

/// The centre REC cap, drawn in the camera surface style the screen injects.
///
/// Both styles share the same things: the 84pt footprint, the presentation
/// state path (an accepted tap shows the stop mark at once, finalizing keeps it
/// but dims it), the press response that moves rather than scales, the circular
/// hit region and the hidden accessibility. Only decoration differs.
///
/// * `.minimal` (the default) is the flat cap: a neutral light disc inside a
///   thin hairline ring, with the semantic red stop mark only while a take is
///   live. No gradient, rim, bevel or shadow.
/// * `.classic` restores the pre-minimal machined plunger: a dark rim, a red
///   gradient body with a bright-over-dark bevel and a cast shadow, white REC
///   lettering at rest and the small white stop square while live.
struct RecordPlungerFace: View {
    let presentation: RecordButtonPresentation
    var isPressed = false
    var rotationDegrees: Double = 0

    @Environment(\.cameraUIStyle) private var uiStyle

    /// Unchanged footprint in both styles: neither cap can resize the shutter row.
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

    /// Finalizing ignores taps, so the mark reads as busy instead of live.
    private var isBusy: Bool {
        presentation == .stopping
    }

    var body: some View {
        Group {
            if uiStyle == .classic {
                classicCap
            } else {
                minimalCap
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .accessibilityHidden(true)
    }

    /// Flat cap: neutral disc, one hairline, semantic red only while live.
    private var minimalCap: some View {
        ZStack {
            Circle()
                .fill(Self.disc)
                .padding(9)
            Circle()
                .strokeBorder(Self.ring, lineWidth: CameraControlBorder.lineWidth)
                .padding(3)
            glyph
        }
        .offset(y: isPressed ? 1.5 : 0)
    }

    /// The pre-minimal machined cap, restored verbatim. The rim, body gradient,
    /// bevel, shadow and press travel are the original tokens; the glyph stays
    /// shared so the state path cannot drift between styles.
    private var classicCap: some View {
        ZStack {
            Circle()
                .fill(classicRim)
                .padding(3)
            Circle()
                .fill(classicBody)
                .overlay {
                    Circle().strokeBorder(classicBevel, lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(isPressed ? 0.25 : 0.65),
                        radius: isPressed ? 1 : 3, x: 0, y: isPressed ? 1 : 4)
                .overlay { glyph }
                .padding(8)
                .offset(y: isPressed ? 1.5 : -1)
        }
    }

    /// Shared state path: the mark appears with the accepted tap and dims while
    /// finalizing in both styles; only the mark's drawing is styled.
    private var glyph: some View {
        Group {
            if showsStopMark {
                stopMark
            } else {
                recLettering
            }
        }
        .rotationEffect(.degrees(rotationDegrees))
    }

    @ViewBuilder
    private var stopMark: some View {
        if uiStyle == .classic {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(isBusy ? 0.4 : 0.9))
                .frame(width: 15, height: 15)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.stopRed)
                .frame(width: 30, height: 30)
                .opacity(isBusy ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private var recLettering: some View {
        if uiStyle == .classic {
            Text("REC")
                .font(NitrateTypography.font(size: 11))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
        } else {
            Text("REC")
                .font(NitrateTypography.font(size: 11))
                .tracking(1)
                .foregroundStyle(.black.opacity(0.62))
        }
    }

    /// Machined rim: dark at the bottom, lifted at the top.
    private var classicRim: LinearGradient {
        LinearGradient(colors: [Color(white: 0.12), Color(white: 0.3)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The red cap body, lit from the top leading corner.
    private var classicBody: LinearGradient {
        LinearGradient(colors: [Color(red: 0.72, green: 0.39, blue: 0.38),
                                Color(red: 0.58, green: 0.26, blue: 0.26),
                                Color(red: 0.43, green: 0.18, blue: 0.19)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Bright along the top edge, dark underneath.
    private var classicBevel: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.06), .black.opacity(0.65)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Gauge readout for the stock group, in either surface style.
///
/// `.minimal` (the default) is type only: the number with `mm` beneath it,
/// stacked so neither is squeezed onto the other's baseline. `.classic`
/// restores the small sepia film strip, whose width follows the selected gauge,
/// with the gauge name printed across it. Both draw inside the existing 28x28
/// slot and rotate with the face, so switching style cannot move the stock row.
struct CameraGaugeLabel: View {
    let gauge: PrintGauge
    var rotationDegrees: Double = 0

    @Environment(\.cameraUIStyle) private var uiStyle

    private var number: String {
        gauge.displayName.replacingOccurrences(of: "mm", with: "")
    }

    /// The classic strip's width follows the format, not the grain multiplier.
    private var stripWidth: CGFloat {
        switch gauge {
        case .eightMillimetre: 12
        case .sixteenMillimetre: 16
        case .thirtyFiveMillimetre: 21
        case .seventyFiveMillimetre: 26
        }
    }

    var body: some View {
        Group {
            if uiStyle == .classic {
                classicReadout
            } else {
                minimalReadout
            }
        }
        .rotationEffect(.degrees(rotationDegrees))
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Print gauge, \(gauge.displayName)")
    }

    private var minimalReadout: some View {
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
    }

    /// The pre-minimal sepia strip and its perforation notches, restored as one
    /// even-odd path so the notches cut through the fill.
    private var classicReadout: some View {
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
    }
}

/// The shipping duotone stock face, independent of the stock-picker interaction.
///
/// Both styles keep the identity stripes and the ISO lettering. `.minimal` (the
/// default) sets the ISO straight onto the swatch; `.classic` restores the
/// material chip behind it. The 44pt swatch and its 1.15 aspect are unchanged,
/// so the chip cannot resize the stock row.
struct CameraFilmStockFace: View {
    let primary: Color
    let secondary: Color
    let isoLight: String
    var faceSize: CGFloat = 44

    @Environment(\.cameraUIStyle) private var uiStyle

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<5) { index in
                    (index == 0 || index == 1 || index == 4 ? primary : secondary)
                        .frame(height: faceSize / 5)
                }
            }
            isoLabel
        }
        .frame(width: faceSize * 1.15, height: faceSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var isoLabel: some View {
        if uiStyle == .classic {
            Text(isoLight)
                .font(NitrateTypography.font(size: 10))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Text(isoLight)
                .font(NitrateTypography.font(size: 11))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
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
