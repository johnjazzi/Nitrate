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

/// Horizontal under/over indicator: the live metered exposure offset against the
/// user's target EV. Sits just above the bottom control rows, about two thirds
/// of the screen width, and turns green when the meter agrees with the target.
///
/// This is the readout that matters in manual ISO: the user dials ISO and wants
/// to know when the centre of the frame (or the selected box) lands on the
/// target exposure.
struct ExposureIndicatorView: View {
    /// Live metered offset from the device target, in EV.
    let meteredEV: Float
    /// The user's chosen EV (0 when no bias is set).
    let targetEV: Float
    let isManual: Bool
    let isAvailable: Bool

    private var matched: Bool {
        isAvailable && ExposureIndicatorPolicy.matches(meteredEV: meteredEV, targetEV: targetEV)
    }

    private var statusText: String {
        guard isAvailable else { return "NO METER" }
        if matched { return "MATCH" }
        return meteredEV < targetEV ? "UNDER" : "OVER"
    }

    private var accent: Color {
        guard isAvailable else { return .white.opacity(0.4) }
        return matched ? .green : (isManual ? .yellow : .orange)
    }

    var body: some View {
        VStack(spacing: 3) {
            header
            track
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure \(statusText.lowercased())")
        .accessibilityValue(String(format: "metered %+.2f EV, target %+.2f EV", meteredEV, targetEV))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("UNDER")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Text(String(format: "%+.1f", meteredEV))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            Text("→ \(String(format: "%+.1f", targetEV))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
            Text(statusText)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(matched ? Color.green : Color.white.opacity(0.85))
                .clipShape(Capsule())
            Spacer(minLength: 0)
            Text("OVER")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                centreTick(width: width, height: height)
                targetBand(width: width, height: height)
                meteredMarker(width: width, height: height)
            }
        }
        .frame(height: 16)
    }

    /// Horizontal position of an EV value on the centred bar.
    private func markerX(_ ev: Float, width: CGFloat) -> CGFloat {
        CGFloat(ExposureIndicatorPolicy.position(ev: ev)) * width
    }

    private func clampedX(_ x: CGFloat, inset: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, inset), max(inset, width - inset))
    }

    private func centreTick(width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.35))
            .frame(width: 1, height: height * 0.6)
            .position(x: width / 2, y: height / 2)
    }

    /// Band marking the user's target EV.
    private func targetBand(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accent.opacity(0.4))
            .frame(width: 10, height: height)
            .position(x: clampedX(markerX(targetEV, width: width), inset: 5, width: width),
                      y: height / 2)
    }

    /// Marker for the live metered offset; green when it agrees with the target.
    private func meteredMarker(width: CGFloat, height: CGFloat) -> some View {
        let diameter = height - 2
        return Circle()
            .fill(matched ? Color.green : Color.white)
            .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .position(x: clampedX(markerX(meteredEV, width: width),
                                  inset: diameter / 2, width: width),
                      y: height / 2)
    }
}
