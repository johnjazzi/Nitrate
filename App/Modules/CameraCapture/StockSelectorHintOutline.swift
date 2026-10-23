import SwiftUI

/// The visual treatment for the stock-selector hint: the whole stock/gauge well
/// is outlined and gently pulses three times, one smooth low-to-high-to-low cycle
/// per second, over its existing ~3-second lifetime.
///
/// Presentation only. It never changes the well's layout, frame, safe area or
/// control height, and it never intercepts a touch (`allowsHitTesting(false)`).
/// It holds no state beyond the phase of the current presentation, so nothing
/// accumulates across previews.
///
/// The envelope lives in `StockSelectorHintPulse` (pure and unit tested); this
/// view only renders it, so the shape cannot drift from the tested contract.
/// Reduce Motion shows the same outline steady, at full strength, and starts no
/// timeline at all.
struct StockSelectorHintOutline: View {
    /// Whether the cue should be on screen. The parent keeps it true for the
    /// cue's lifetime; a false-to-true edge is a new presentation and restarts
    /// the phase from the dim low.
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isVisible {
            if reduceMotion {
                // Steady outline instead of a pulse: no timeline, no updates.
                StockSelectorHintRing()
                    .opacity(StockSelectorHintPulse.maximumOpacity)
            } else {
                StockSelectorHintPulseFace()
            }
        }
    }
}

/// The ring geometry, shared by the steady and pulsing treatments so the cue
/// stays visually identical to the previous one-shot outline.
private struct StockSelectorHintRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
            .shadow(color: .white.opacity(0.45), radius: 4)
    }
}

/// Drives the ring's opacity from the tested envelope.
///
/// The timeline exists only while the cue is visible and motion is allowed, and
/// the phase clock is created with this view, so each presentation begins at the
/// dim low and no timer or phase survives a hidden cue. The envelope reaches 0
/// at the end of the cue's lifetime, so a late frame simply renders nothing.
private struct StockSelectorHintPulseFace: View {
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            StockSelectorHintRing()
                .opacity(StockSelectorHintPulse.opacity(
                    elapsed: context.date.timeIntervalSince(startedAt)))
        }
        .allowsHitTesting(false)
    }
}
