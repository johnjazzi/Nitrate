import SwiftUI

enum FocalLengthRulerScale {
    static let majorTicks = CameraFocalZoomPolicy.majorTicks
    static let minorTicks: [Double] = stride(
        from: 15.0, through: CameraFocalZoomPolicy.maximumFocalLengthMM, by: 5
    ).filter { !majorTicks.contains($0) }

    static func offset(millimeters: Double, selected: Double) -> Double {
        guard millimeters.isFinite, selected.isFinite, millimeters > 0, selected > 0 else { return 0 }
        return log2(millimeters / selected) * 128
    }

    static func crossesMajorTick(from old: Double, to new: Double) -> Bool {
        guard old.isFinite, new.isFinite, old != new else { return false }
        return majorTicks.contains { tick in
            new > old ? old < tick && new >= tick : old > tick && new <= tick
        }
    }
}

/// A moving focal-length scale under a fixed index, shown only during a pinch.
/// The overlay does not participate in preview/control measurements.
struct FocalLengthRuler: View {
    let millimeters: Double

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Int(millimeters.rounded())) mm")
                .font(NitrateTypography.font(size: 12))
                .foregroundStyle(.yellow)
            Canvas { context, size in
                for value in FocalLengthRulerScale.minorTicks {
                    let x = size.width / 2 + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard x >= 0, x <= size.width else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 5))
                    context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                }
                for value in FocalLengthRulerScale.majorTicks {
                    let x = size.width / 2 + FocalLengthRulerScale.offset(millimeters: value, selected: millimeters)
                    guard x >= 10, x <= size.width - 10 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 10))
                    context.stroke(path, with: .color(.white), lineWidth: 1)
                    context.draw(Text("\(Int(value))")
                        .font(NitrateTypography.font(size: 9))
                        .foregroundStyle(.white), at: CGPoint(x: x, y: 20))
                }
                var index = Path()
                index.move(to: CGPoint(x: size.width / 2, y: 0))
                index.addLine(to: CGPoint(x: size.width / 2, y: 12))
                context.stroke(index, with: .color(.yellow), lineWidth: 2)
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focal length")
        .accessibilityValue("\(Int(millimeters.rounded())) millimeters")
    }
}
