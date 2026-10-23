import SwiftUI

/// Flat modern REC face. Shares the classic plunger's 84pt footprint, tap
/// handling, haptics and press feedback; only the drawn appearance differs.
///
/// Idle shows a black disc with a red rim and REC mark. An accepted tap fills
/// the disc red and shows the stop square immediately, allowing startup to be
/// cancelled. Only finalization dims the face. Reduce Motion swaps instantly.
struct ModernRecordButtonFace: View {
    let presentation: RecordButtonPresentation
    var isPressed = false
    var rotationDegrees: Double = 0
    var reduceMotion = false

    private static let diameter: CGFloat = 84

    /// One brand red for the rim, the REC mark and the recording fill. Reused
    /// from the recording lamp, so no new palette colour is introduced.
    private static let red = Color(red: 0.95, green: 0.22, blue: 0.18)

    /// The same mark cancels startup, stops capture, and remains during draining.
    private var showsStopSymbol: Bool {
        presentation != .idle
    }

    private var fillsRed: Bool { showsStopSymbol }

    /// Startup remains fully visible and cancellable; finalization ignores taps.
    private var isBusy: Bool {
        presentation == .stopping
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillsRed ? Self.red : Color.black)
            Circle()
                .strokeBorder(Self.red, lineWidth: 3)
            glyph
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        // A small, non-layout press response: the modern face depresses by
        // scale, never by changing its reserved 84pt footprint.
        .scaleEffect(isPressed ? 0.96 : 1)
        .opacity(isBusy ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: RecordButtonAppearanceTiming.morphDuration),
                   value: presentation)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
        .accessibilityHidden(true)
    }

    /// Both glyphs are always present and crossfade by opacity, so switching
    /// states never reflows the face. Rotated with the shared orientation
    /// mapping, exactly like the classic face's mark.
    private var glyph: some View {
        ZStack {
            Text("REC")
                .font(NitrateTypography.font(size: 16))
                .tracking(1)
                .foregroundStyle(Self.red)
                .opacity(showsStopSymbol ? 0 : 1)
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .frame(width: 24, height: 24)
                .opacity(showsStopSymbol ? 1 : 0)
        }
        .rotationEffect(.degrees(rotationDegrees))
    }
}
