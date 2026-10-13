import SwiftUI

/// White information on dark green; the entire face is one queue control.
struct RecordingTimeLCD: View {
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

            Text(CameraStatusPresentation.compactTimeText(for: estimatedSeconds))
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
                if queueStatus.hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else if queueStatus.isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(queueStatus.label)
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

    static func timeText(for seconds: TimeInterval?) -> String {
        CameraStatusPresentation.timeText(for: seconds)
    }
}
