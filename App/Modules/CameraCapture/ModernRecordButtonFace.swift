import SwiftUI

/// Flat modern REC face. Shares the classic plunger's 84pt footprint, tap
/// handling, haptics and press feedback; only the drawn appearance differs.
///
/// Idle and a pending start are a black disc with a red rim and a red REC mark.
/// A confirmed take fills the disc red and swaps the mark for a white stop
/// square. `.starting` and `.stopping` are explicitly busy — dimmed, and for
/// `.starting` still showing REC — so the control never claims a take has been
/// confirmed before it has, and never paints a stop square until the take is
/// live. Reduce Motion swaps states instantly instead of morphing.
struct ModernRecordButtonFace: View {
    let presentation: RecordButtonPresentation
    var isPressed = false
    var rotationDegrees: Double = 0
    var reduceMotion = false

    private static let diameter: CGFloat = 84

    /// One brand red for the rim, the REC mark and the recording fill. Reused
    /// from the recording lamp, so no new palette colour is introduced.
    private static let red = Color(red: 0.95, green: 0.22, blue: 0.18)

    /// A stop square belongs only to a live take or its finalisation. A pending
    /// start keeps the idle mark, so it cannot imply capture has begun.
    private var showsStopSymbol: Bool {
        presentation == .recording || presentation == .stopping
    }

    private var fillsRed: Bool { showsStopSymbol }

    /// `.starting` is pending and `.stopping` is finalizing: both are dimmed so
    /// the state reads as not-yet/not-longer an ordinary tap, mirroring the
    /// classic face's dimmed stop square. Nothing about the tap action changes —
    /// `RecordButtonPresentationPolicy` still owns what a tap does.
    private var isBusy: Bool {
        presentation == .starting || presentation == .stopping
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
