import SwiftUI

/// The in-frame vertical zoom ruler the live Zoom toggle shows in place of the
/// old bottom strip. It is authored in the upright portrait axis — a 44pt
/// column — so `FrameRulerSlot` can carry it to the physical left edge in every
/// hold while its glyphs stay readable.
///
/// Everything is bounded by the granted slot and clipped, so no intrinsic width
/// can overflow the column, and the cosmetic rail never takes hits: only the two
/// hold arrows are interactive, so the preview underneath the rail still
/// receives its own taps.
///
/// The arrows reuse `ZoomHoldControl`, the same begin/end/revision protocol as
/// the manual panel's hold keys, so release, drag-off and a revision change
/// cancel the ramp identically.
struct FrameZoomRuler: View {
    let millimeters: Double
    let enabled: Bool
    let revision: UInt64
    let begin: (CameraZoomDirection) -> Void
    let end: (UInt64) -> Void
    let step: (CameraZoomDirection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            arrow(.in, symbol: "chevron.up", label: "Zoom in")
            rail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            arrow(.out, symbol: "chevron.down", label: "Zoom out")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func arrow(_ direction: CameraZoomDirection, symbol: String, label: String) -> some View {
        ZoomHoldControl(symbol: symbol, label: label, enabled: enabled, revision: revision,
                        begin: { begin(direction) }, end: end, step: { step(direction) })
    }

    private var rail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45))
            Canvas { context, size in
                let center = size.height / 2
                for value in stride(from: 15.0, through: 150, by: 5)
                where !FocalLengthRulerScale.majorTicks.contains(value) {
                    let y = center + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard y >= 0, y <= size.height else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 5, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                }
                for value in FocalLengthRulerScale.majorTicks {
                    let y = center + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard y >= 8, y <= size.height - 8 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 10, y: y))
                    context.stroke(path, with: .color(.white), lineWidth: 1)
                    context.draw(Text("\(Int(value))")
                        .font(NitrateTypography.font(size: 9))
                        .foregroundStyle(.white),
                        at: CGPoint(x: size.width * 0.62, y: y))
                }
                var index = Path()
                index.move(to: CGPoint(x: 0, y: center))
                index.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(index, with: .color(.yellow), lineWidth: 2)
            }
            Text(readout)
                .font(NitrateTypography.font(size: 9))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.65), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom focal length")
        .accessibilityValue(readout)
    }

    /// A finite focal readout; non-finite input shows a dash rather than
    /// trapping on `Int(_:)`.
    private var readout: String {
        guard millimeters.isFinite else { return "—" }
        return "\(Int(millimeters.rounded()))mm"
    }
}
