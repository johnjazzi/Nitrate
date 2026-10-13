import SwiftUI

/// Thin outline marking where exposure is metered on the preview: the frame
/// centre by default, the tapped point after a tap-to-focus. Dashed while auto
/// exposure drives the scene, solid while manual ISO does. Hidden during a take
/// so it never draws over the recording.
struct MeteringBoxView: View {
    /// Normalised (0–1) centre of the box in the preview's coordinate space.
    let point: CGPoint
    let isManual: Bool

    private let boxSize = CGSize(width: 78, height: 62)

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isManual ? Color.yellow.opacity(0.95) : Color.white.opacity(0.8),
                    style: StrokeStyle(lineWidth: 1.5, dash: isManual ? [] : [6, 4])
                )
                .frame(width: boxSize.width, height: boxSize.height)
                .position(x: point.x * geometry.size.width,
                          y: point.y * geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Compact live meter beside the exposure ruler. Higher EV is above centre,
/// matching the ruler's direction; the target band and live dot retain the
/// same absolute EV scale and match tolerance as the original horizontal meter.
struct ExposureIndicatorView: View {
    let meteredEV: Float
    let targetEV: Float
    let isManual: Bool
    let isAvailable: Bool

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

    private var accent: Color {
        guard hasReading else { return .white.opacity(0.4) }
        return matched ? .green : (isManual ? .yellow : .orange)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(hasReading ? String(format: "%+.1f", meteredEV) : "—")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .cameraUpright()
                .frame(height: 14)
            VStack(spacing: 2) {
                directionLabel("OVER")
                track
                directionLabel("UNDER")
            }
            .frame(height: 120)
            Text(statusText)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(accent)
                .cameraUpright()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 28)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure \(statusText.lowercased())")
        .accessibilityValue(hasReading
            ? String(format: "metered %+.2f EV, target %+.2f EV", meteredEV, targetEV)
            : "Live exposure meter unavailable")
    }

    private func directionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white.opacity(0.6))
            .cameraUpright()
            .frame(height: 8)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: width * 0.6, height: 1)
                    .position(x: width / 2, y: height / 2)
                // No live dot or target band when there is no valid reading:
                // an unknown meter must not look like a centred match.
                if hasReading {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent.opacity(0.4))
                        .frame(width: width, height: 10)
                        .position(x: width / 2, y: markerY(targetEV, inset: 5, height: height))
                    Circle()
                        .fill(matched ? Color.green : Color.white)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                        .frame(width: width - 2, height: width - 2)
                        .position(x: width / 2,
                                  y: markerY(meteredEV, inset: (width - 2) / 2, height: height))
                }
            }
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
    }

    private func markerY(_ ev: Float, inset: CGFloat, height: CGFloat) -> CGFloat {
        let position = (1 - CGFloat(ExposureIndicatorPolicy.position(ev: ev))) * height
        return min(max(position, inset), max(inset, height - inset))
    }
}
