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

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headline
                if let detail {
                    Text(detail)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .opacity(isBright ? 1 : 0.3)
        .onAppear {
            guard !reduceMotion else {
                isBright = true
                return
            }
            withAnimation(.easeInOut(duration: 0.12).repeatCount(12, autoreverses: true)) {
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
