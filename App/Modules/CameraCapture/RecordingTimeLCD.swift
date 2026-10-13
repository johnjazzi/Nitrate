import SwiftUI

/// White information on dark green; the entire face is one queue control.
struct RecordingTimeLCD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let estimatedSeconds: TimeInterval?
    let isStorageLow: Bool
    let queueStatus: CameraStatusPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("REC LEFT")
                    .font(.system(size: 8, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "list.bullet")
                    .font(.system(size: 8, weight: .semibold))
                if let count = queueStatus.countText {
                    Text(count)
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(0.75))

            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 0.5)

            if queueStatus.isProcessing {
                renderingActivity
            } else {
                remainingTime(fontSize: 20)
                    .frame(maxHeight: .infinity)
            }

            HStack(spacing: 3) {
                if queueStatus.isProcessing {
                    remainingTime(fontSize: 11)
                }
                if queueStatus.hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else if queueStatus.isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if !queueStatus.isProcessing {
                    Text(queueStatus.label)
                }
                Spacer(minLength: 0)
                if isStorageLow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(red: 0.055, green: 0.14, blue: 0.105))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.black.opacity(0.8), .white.opacity(0.25)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
        }
    }

    private func remainingTime(fontSize: CGFloat) -> some View {
        Text(CameraStatusPresentation.compactTimeText(for: estimatedSeconds))
            .font(.system(size: fontSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderingActivity: some View {
        VStack(spacing: 2) {
            // The timeline exists only during active rendering with motion enabled.
            // A static arc replaces it under Reduce Motion; no animation state or timer survives idle.
            if queueStatus.shouldAnimateRendering(reduceMotion: reduceMotion) {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.2) / 1.2
                    loadingRing(rotation: phase * 360)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            } else {
                loadingRing(rotation: 0)
                    .accessibilityHidden(true)
            }
            Text("RENDERING")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingRing(rotation: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .frame(width: 18, height: 18)
    }

    static func timeText(for seconds: TimeInterval?) -> String {
        CameraStatusPresentation.timeText(for: seconds)
    }
}
