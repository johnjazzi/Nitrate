import SwiftUI

/// Shared preference for the visual metering indicator. The Settings toggle and
/// the preview both read this key, and the indicator is on by default, so an
/// install that has never opened Settings still shows it. It only controls the
/// indicator's visibility: the tap-to-focus handler and metering point are
/// unaffected.
enum MeteringIndicatorPreferences {
    static let showsIndicatorKey = "camera.showsMeteringIndicator"
    static let defaultShowsIndicator = true
}

/// Thin circle marking where exposure is metered on the preview: the frame
/// centre by default, the tapped point after a tap-to-focus. Dashed while auto
/// exposure drives the scene, solid while manual ISO does. Hidden during a take
/// so it never draws over the recording.
struct MeteringBoxView: View {
    /// Normalised (0–1) centre of the indicator in the preview's coordinate space.
    let point: CGPoint
    let isManual: Bool
    /// Controls only the ring inside the fixed overlay geometry.
    var isVisible: Bool = true

    /// Semantic diameter of the circle, kept as a single value so the ring stays
    /// inside its frame with `strokeBorder`.
    private let diameter: CGFloat = 72

    var body: some View {
        GeometryReader { geometry in
            if isVisible {
                Circle()
                    .strokeBorder(
                        isManual ? Color.yellow.opacity(0.95) : Color.white.opacity(0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: isManual ? [] : [6, 4])
                    )
                    .frame(width: diameter, height: diameter)
                    .position(x: point.x * geometry.size.width,
                              y: point.y * geometry.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

