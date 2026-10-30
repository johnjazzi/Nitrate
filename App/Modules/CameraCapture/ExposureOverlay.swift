import SwiftUI

/// Compact live meter beside the exposure ruler. Higher EV is above centre,
/// matching the ruler's direction; the target band and live dot retain the
/// same absolute EV scale and match tolerance as the original horizontal meter.
struct ExposureIndicatorView: View {
    let meteredEV: Float
    let targetEV: Float
    let isManual: Bool
    let isAvailable: Bool
    var trackHeight: CGFloat = 120

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
                .font(NitrateTypography.font(size: 10))
                .foregroundStyle(accent)
                .cameraUpright()
                .frame(height: 14)
            // The meter keeps its 120pt scale, centre line, target band and live
            // dot without the former visible OVER/UNDER captions, so the column
            // footprint is unchanged and the meter stays aligned with the ruler.
            // Direction and status survive only in the VoiceOver label below.
            track
                .frame(height: trackHeight)
        }
        .frame(width: 28)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure \(statusText.lowercased())")
        .accessibilityValue(hasReading
            ? String(format: "metered %+.2f EV, target %+.2f EV", meteredEV, targetEV)
            : "Live exposure meter unavailable")
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
