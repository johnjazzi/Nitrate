import SwiftUI

/// Rotate the capsule and its natural-size digits together, never fit the digits
/// back into their shallow portrait bounds. Reserve the turned face above REC.
struct RecordingTimerBadge: View {
    let text: String
    let isStopping: Bool
    let rotationDegrees: Double

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(width: 84, height: 24)
            .background(isStopping ? Color.gray.opacity(0.85) : Color.red.opacity(0.8))
            .clipShape(Capsule())
            .rotationEffect(.degrees(rotationDegrees))
            // Reserve the swapped bounds so the capsule never crosses REC.
            .frame(width: abs(rotationDegrees) == 90 ? 24 : 84,
                   height: abs(rotationDegrees) == 90 ? 84 : 24)
    }
}
