import SwiftUI

/// What the LCD's centre reports. A confirmed, still-live take outranks render
/// queue activity; the pending-start and finalising windows never read as an
/// active recording.
enum RecordingTimeLCDFocus: Equatable, Sendable {
    case recording
    case rendering
    case remaining

    static func resolve(isRecording: Bool, isStopping: Bool, isProcessing: Bool) -> Self {
        if isRecording && !isStopping { return .recording }
        if isProcessing { return .rendering }
        return .remaining
    }
}

/// White information on the neutral control surface; the entire face opens the queue.
///
/// The headline is the highest-priority state on the bar: an active take owns
/// it as `RECORDING`, but the queue count, the storage warning and the tap
/// target stay live throughout, and the remaining recording time is never
/// displaced.
struct RecordingTimeLCD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let estimatedSeconds: TimeInterval?
    let isStorageLow: Bool
    let queueStatus: CameraStatusPresentation
    /// Active capture only: true between a confirmed start and the stop tap.
    var isRecording = false
    /// Stop acknowledged, recorder still finalising. The take is live but is no
    /// longer an active recording, so the headline must drop back.
    var isStopping = false

    private var focus: RecordingTimeLCDFocus {
        .resolve(isRecording: isRecording, isStopping: isStopping, isProcessing: queueStatus.isProcessing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            headline
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 0.5)
            if focus == .rendering {
                renderingActivity
            } else {
                remainingTime(fontSize: 20)
                    .frame(maxHeight: .infinity)
            }
            statusRow
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .modifier(CameraInsetSurface())
    }

    /// Recording owns this line. The queue count stays beside it so the queue is
    /// reachable and visible during a take.
    private var headline: some View {
        HStack(spacing: 3) {
            if focus == .recording {
                Circle().fill(.red).frame(width: 5, height: 5)
            }
            Text(focus == .recording ? "RECORDING" : "REC LEFT")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "list.bullet")
            if let count = queueStatus.countText {
                Text(count)
                    .font(NitrateTypography.font(size: 8).monospacedDigit())
            }
        }
        .font(NitrateTypography.font(size: 8))
        .foregroundStyle(.white.opacity(focus == .recording ? 0.95 : 0.75))
    }

    /// Queue, delivery and storage state. Rendering is the only state that shows
    /// the abbreviated remaining time here, because it owns the centre instead.
    private var statusRow: some View {
        HStack(spacing: 3) {
            if focus == .rendering {
                remainingTime(fontSize: 11)
            }
            if queueStatus.hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if queueStatus.isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if focus != .rendering {
                Text(queueStatus.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isStorageLow {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(NitrateTypography.font(size: 8))
        .foregroundStyle(.white.opacity(0.8))
    }

    private func remainingTime(fontSize: CGFloat) -> some View {
        Text(CameraStatusPresentation.compactTimeText(for: estimatedSeconds))
            .font(NitrateTypography.font(size: fontSize))
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
                .font(NitrateTypography.font(size: 12))
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
