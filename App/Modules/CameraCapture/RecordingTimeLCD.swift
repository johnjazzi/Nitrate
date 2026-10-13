import SwiftUI

/// Modern camera status display: white information on a solid dark-green face.
/// The caller supplies the real storage estimate; no decorative readings.
struct RecordingTimeLCD: View {
    let estimatedSeconds: TimeInterval?
    let isStorageLow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("REC LEFT")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                Spacer(minLength: 0)
                if isStorageLow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.white.opacity(0.75))

            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 0.5)

            Text(Self.timeText(for: estimatedSeconds))
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
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

    /// Include hours when needed; unknown/invalid estimates show dashes.
    static func timeText(for seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max) else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, remainder)
        }
        return String(format: "%02ld:%02ld", minutes, remainder)
    }
}
