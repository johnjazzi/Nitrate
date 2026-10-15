import SwiftUI

/// The dramatic treatment for a take that never started.
///
/// White compressed caps over a red bloom, in the spirit of an instrument-panel
/// warning card. Deliberately not a red field: it has to stay legible over a live
/// camera preview, so the warning sits on a dark scrim instead. It strobes for
/// about 1.4 s and then goes away on its own — it is an attention grab, not a
/// dialog to dismiss.
struct RecordingFailureOverlay: View {
    /// The concrete reason, shown small under the headline. Optional because the
    /// headline alone is the point.
    let detail: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    /// Slow enough to read rather than strobe. The first cut used 0.12 s per
    /// phase — about 8 Hz, which is both too fast to read and inside the range
    /// that can trigger photosensitive seizures. This is eight times slower.
    static let flashHalfCycle: TimeInterval = 0.96

    /// Two cycles: the card stays up for a bit under four seconds.
    static let flashCycles = 2

    /// How long the card is on screen. The screen holds it for this long so the
    /// animation cannot be cut off part-way through a cycle.
    static var flashDuration: TimeInterval { flashHalfCycle * Double(flashCycles) * 2 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headline
                    // Only the headline pulses. The reason line stays steady and
                    // the scrim never fades, so the card reads as a card with a
                    // throbbing warning on it rather than a flickering screen.
                    .opacity(isBright ? 1 : 0.55)
                if let detail {
                    Text(detail)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else {
                isBright = true
                return
            }
            withAnimation(.easeInOut(duration: Self.flashHalfCycle)
                .repeatCount(Self.flashCycles, autoreverses: true)) {
                isBright = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Computer malfunction. The recording did not start.")
    }

    private var headline: some View {
        VStack(spacing: -4) {
            Text("COMPUTER")
            Text("MALFUNCTION")
        }
        .font(.system(size: 46, weight: .black).width(.compressed))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .shadow(color: Color.red.opacity(0.95), radius: 2)
        .shadow(color: Color.red.opacity(0.8), radius: 8)
        .shadow(color: Color.red.opacity(0.55), radius: 18)
        .padding(.horizontal, 24)
    }
}
