import SwiftUI

/// Read-only live meter at the preview's bottom edge. Its absolute EV scale and
/// target-match tolerance are unchanged; adjustment remains in the shooting bar.
struct ExposureIndicatorView: View {
    let meteredEV: Float
    let targetEV: Float
    let isManual: Bool
    let isAvailable: Bool
    @Environment(\.cameraControlAccent) private var controlAccent
    @Environment(\.cameraUIStyle) private var uiStyle

    private var hasReading: Bool {
        isAvailable && meteredEV.isFinite && targetEV.isFinite
    }

    private var matched: Bool {
        hasReading && ExposureIndicatorPolicy.matches(meteredEV: meteredEV, targetEV: targetEV)
    }

    private var statusText: String {
        guard hasReading else { return "NO METER" }
        if matched { return "MATCH" }
        return meteredEV < targetEV ? "UNDER" : "OVER"
    }

    var body: some View {
        Group {
            if uiStyle == .classic { verticalMeter } else { horizontalMeter }
        }
        .cameraRulerBackdrop()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("camera.measuredExposure")
        .accessibilityLabel("\(isManual ? "Manual" : "Auto") exposure \(statusText.lowercased())")
        .accessibilityValue(hasReading
            ? String(format: "metered %+.2f EV, target %+.2f EV", meteredEV, targetEV)
            : "Live exposure meter unavailable")
    }

    private var horizontalMeter: some View {
        VStack(spacing: 4) {
            Text(hasReading ? String(format: "%+.1f", meteredEV) : "—")
                .font(NitrateTypography.font(size: 11).monospacedDigit())
                .foregroundStyle(hasReading ? controlAccent : .white.opacity(0.5))
#if os(iOS)
                .cameraUpright()
#endif
                .frame(height: 14)
            track.frame(height: 14)
        }
        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
    }

    private var verticalMeter: some View {
        VStack(spacing: 6) {
            Text(hasReading ? String(format: "%+.1f", meteredEV) : "—")
                .font(NitrateTypography.font(size: 10).monospacedDigit())
                .foregroundStyle(hasReading ? controlAccent : .white.opacity(0.5))
#if os(iOS)
                .cameraUpright()
#endif
                .frame(height: 14)
            GeometryReader { geometry in
                let height = geometry.size.height
                ZStack {
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 7, height: 1)
                    if hasReading {
                        RoundedRectangle(cornerRadius: 2).fill(controlAccent.opacity(0.4))
                            .frame(width: 12, height: 10)
                            .position(x: 6, y: markerY(targetEV, inset: 5, height: height))
                        Circle().fill(controlAccent)
                            .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                            .frame(width: 10, height: 10)
                            .position(x: 6, y: markerY(meteredEV, inset: 5, height: height))
                    }
                }
            }
            .frame(width: 12, height: 120)
        }
        .frame(width: 28)
    }

    private func markerY(_ ev: Float, inset: CGFloat, height: CGFloat) -> CGFloat {
        let position = (1 - CGFloat(ExposureIndicatorPolicy.position(ev: ev))) * height
        return min(max(position, inset), max(inset, height - inset))
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 4)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for index in 0...24 {
                        let x = 2 + CGFloat(index) / 24 * width
                        path.move(to: CGPoint(x: x, y: 14))
                        path.addLine(to: CGPoint(x: x, y: index.isMultiple(of: 4) ? 5 : 9))
                    }
                }
                .stroke(.white.opacity(hasReading ? 0.55 : 0.2), lineWidth: 0.5)
                if hasReading {
                    // Target is an outline; the measured value is the solid
                    // pointer, so matching does not depend on a second hue.
                    Circle().strokeBorder(controlAccent, lineWidth: 1)
                        .frame(width: 6, height: 6)
                        .position(x: markerX(targetEV, width: width), y: 3)
                    Rectangle().fill(controlAccent)
                        .frame(width: 2, height: 12)
                        .position(x: markerX(meteredEV, width: width), y: 8)
                }
            }
        }
    }

    private func markerX(_ ev: Float, width: CGFloat) -> CGFloat {
        2 + CGFloat(ExposureIndicatorPolicy.position(ev: ev)) * width
    }
}
