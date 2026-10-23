import SwiftUI

/// Pure scale/behaviour for the in-frame manual-focus ruler. The ruler shows a
/// raw normalised lens position (0…1), never a fabricated distance: this is the
/// same value the hardware locks, mapped to the physical track.
enum ManualFocusRulerScale {
    /// One VoiceOver / step increment, in raw lens-position units.
    static let step: Double = 0.01

    /// Clamp a raw lens position into 0…1. Non-finite input falls back to the
    /// mid travel rather than pinning the lens to an extreme.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    /// Fraction down the physical track for a lens position: 0 at the top
    /// (lens position 1, far) and 1 at the bottom (lens position 0, near), so
    /// the index reads the same way the lens travels.
    static func indexFraction(lensPosition: Double) -> Double {
        guard lensPosition.isFinite else { return 0.5 }
        return min(max(1 - lensPosition, 0), 1)
    }

    /// Lens position for a drag `offset` from the top of a `length`-long track.
    /// Nil for a non-finite offset or a zero-length track.
    static func lensPosition(offsetFromTop: Double, length: Double) -> Double? {
        guard offsetFromTop.isFinite, length.isFinite, length > 0 else { return nil }
        return clamped(1 - offsetFromTop / length)
    }

    /// One bounded adjustment, clamped to the raw lens range.
    static func adjusted(lensPosition: Double, by delta: Double) -> Double {
        clamped((lensPosition.isFinite ? lensPosition : 0.5) + delta)
    }
}

/// An interactive normalised manual-focus ruler: a yellow index over a fixed
/// tick rail, styled after `FocalLengthRuler`. It writes the raw lens position
/// directly, so the owning screen issues the single hardware write, and it
/// carries the same 44pt hit width and VoiceOver adjustable action as the other
/// camera controls.
struct ManualFocusRuler: View {
    @Binding var lensPosition: Double
    let enabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text("MF")
                .font(NitrateTypography.font(size: 11))
                .foregroundStyle(.yellow)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.45))
                    Canvas { context, size in
                        for tick in stride(from: 0.0, through: 1.0, by: 0.1) {
                            let y = size.height * tick
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: 6, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                        }
                        for tick in stride(from: 0.0, through: 1.0, by: 0.5) {
                            let y = size.height * tick
                            var path = Path()
                            path.move(to: CGPoint(x: size.width - 6, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                        }
                    }
                    Rectangle()
                        .fill(.yellow)
                        .frame(width: geometry.size.width, height: 2)
                        .position(x: geometry.size.width / 2,
                                  y: ManualFocusRulerScale.indexFraction(lensPosition: lensPosition)
                                      * geometry.size.height)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard enabled else { return }
                            guard let position = ManualFocusRulerScale.lensPosition(
                                offsetFromTop: Double(value.location.y),
                                length: Double(geometry.size.height)) else { return }
                            lensPosition = position
                        }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Manual focus")
            .accessibilityValue("\(Int((ManualFocusRulerScale.clamped(lensPosition) * 100).rounded())) percent")
            .accessibilityHint("Adjusts the focus distance")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                let delta = direction == .increment ? ManualFocusRulerScale.step
                                                    : -ManualFocusRulerScale.step
                lensPosition = ManualFocusRulerScale.adjusted(lensPosition: lensPosition, by: delta)
            }
        }
        .frame(width: 44)
        .disabled(!enabled)
    }
}
