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

/// Minimal is quiet type: this face paints no surface, box or rim of its own, with
/// a 16pt queue glyph named QUEUE so the queue stays legible at a glance. The
/// shooting bar seats the whole face in the shared Minimal well, so the plate is
/// drawn once by the bar and not again here. Classic restores the old recessed
/// LCD — the shared inset surface, the hairline under the headline, the bare 8pt
/// queue glyph and the prominent 20pt readout centred in the plate. In both the entire face is the one queue action: the glyph and
/// its label are decoration, so the LCD never grows a second, smaller target and
/// its touch area never drops below `minimumTouchSize`.
///
/// The headline is the highest-priority state on the bar: an active take owns
/// it as `RECORDING`, but the queue count, the storage warning and the tap
/// target stay live throughout, and the remaining recording time is never
/// displaced by an abbreviated placeholder.
struct RecordingTimeLCD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Presentation only. Every status, queue, storage and capture semantic
    /// below is shared by both styles.
    @Environment(\.cameraUIStyle) private var uiStyle
    let estimatedSeconds: TimeInterval?
    let isStorageLow: Bool
    let queueStatus: CameraStatusPresentation
    /// Active capture only: true between a confirmed start and the stop tap.
    var isRecording = false
    /// Stop acknowledged, recorder still finalising. The take is live but is no
    /// longer an active recording, so the headline must drop back.
    var isStopping = false
    var photoFreeBytes: Int64? = nil
    var isPhotoMode = false
    var isRenderingPhoto = false
    var isSavingPhoto = false

    var showsRenderingActivity: Bool { focus == .rendering }
    var renderActivityLabel: String { isSavingPhoto ? "SAVING" : "RENDERING" }
    var headlineText: String {
        if focus == .recording { return "RECORDING" }
        if focus == .rendering, isRenderingPhoto { return "PHOTO" }
        return isPhotoMode || photoFreeBytes != nil ? "FREE SPACE" : "REC LEFT"
    }

    var capacityText: String {
        guard let photoFreeBytes else { return "-- GB" }
        return String(format: "%.1f GB", Double(max(0, photoFreeBytes)) / 1_000_000_000)
    }

    private var focus: RecordingTimeLCDFocus {
        .resolve(isRecording: isRecording, isStopping: isStopping, isProcessing: queueStatus.isProcessing)
    }

    private var isClassic: Bool { uiStyle == .classic }

    /// The smallest this face is ever offered as a tap target. The whole LCD is
    /// the queue action, so its touch area is never a glyph-sized sub-target.
    static let minimumTouchSize: CGFloat = 44

    /// Minimal's queue mark. Big enough to read over bright footage, and named
    /// beside it so the mark is not the only cue.
    static let queueGlyphSize: CGFloat = 16

    /// The visible name of the queue action in Minimal.
    static let queueCaption = "QUEUE"

    var body: some View {
        presentation
            .frame(minWidth: Self.minimumTouchSize, minHeight: Self.minimumTouchSize)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var presentation: some View {
        if isClassic {
            // The old recessed plate. The shared inset surface is reused as-is,
            // so Classic grows no material, rim or second chrome owner.
            stack
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .modifier(CameraInsetSurface())
        } else {
            // Unboxed: the type sits on the image with a soft shadow for
            // contrast instead of a plate, inset surface or hairline divider.
            // It fills its slot, so the whole face stays one large target.
            stack
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
        }
    }

    /// One status stack for both styles. Only the readout's type size and its
    /// fill of the plate differ; queue, storage, photo and render state are the
    /// same view in both.
    private var stack: some View {
        VStack(alignment: .leading, spacing: 3) {
            headline
            if isClassic {
                Rectangle()
                    .fill(.white.opacity(0.22))
                    .frame(height: 0.5)
            }
            center
            statusRow
        }
    }

    /// The plate's middle row: render activity, photo capacity or remaining
    /// time. Classic restores the prominent 20pt readout and centres it in the
    /// space between the headline and the status row; Minimal keeps the quiet
    /// 12pt line.
    @ViewBuilder
    private var center: some View {
        if showsRenderingActivity {
            renderingActivity
        } else if isPhotoMode || photoFreeBytes != nil {
            capacityReadout
        } else {
            remainingReadout
        }
    }

    @ViewBuilder
    private var capacityReadout: some View {
        if isClassic {
            capacityLabel(size: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            capacityLabel(size: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capacityLabel(size: CGFloat) -> some View {
        Text(capacityText)
            .font(NitrateTypography.font(size: size)).monospacedDigit()
            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private var remainingReadout: some View {
        if isClassic {
            remainingTime(fontSize: 20)
                .frame(maxHeight: .infinity)
        } else {
            remainingTime(fontSize: 12)
        }
    }

    /// Recording owns this line. The queue count stays beside it so the queue is
    /// reachable and visible during a take. Minimal adds the named, full-size
    /// queue mark here; Classic keeps the original bare glyph and count.
    private var headline: some View {
        HStack(spacing: 3) {
            if focus == .recording {
                Circle().fill(.red).frame(width: 5, height: 5)
            }
            Text(headlineText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            queueMark
        }
        .font(NitrateTypography.font(size: 8))
        .foregroundStyle(.white.opacity(isClassic ? (focus == .recording ? 0.95 : 0.75)
                                                  : (focus == .recording ? 0.85 : 0.6)))
    }

    /// The queue affordance. Classic keeps the original 8pt glyph and bare
    /// count. Minimal paints a 16pt glyph in full white with an explicit QUEUE
    /// label and the count, so the queue reads without relying on the tiny
    /// headline. Both are decoration: the whole LCD remains the one tap target
    /// and the parent's button owns the spoken queue value.
    @ViewBuilder
    private var queueMark: some View {
        if isClassic {
            Image(systemName: "list.bullet")
                .accessibilityHidden(true)
            if let count = queueStatus.countText {
                Text(count)
                    .font(NitrateTypography.font(size: 8).monospacedDigit())
                    .accessibilityHidden(true)
            }
        } else {
            HStack(spacing: 2) {
                Image(systemName: "list.bullet")
                    // The symbol is sized by the same type scale as the app's
                    // text; no system font family is introduced for it, and no
                    // weight override (a custom family cannot re-weight, so the
                    // descriptor warning that produced was pure log noise).
                    .font(NitrateTypography.font(size: Self.queueGlyphSize))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 0) {
                    if let count = queueStatus.countText {
                        Text(count)
                            .font(NitrateTypography.font(size: 9).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    Text(Self.queueCaption)
                        .font(NitrateTypography.font(size: 7, relativeTo: .caption2))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Queue, delivery and storage state. Rendering is the only state that shows
    /// the abbreviated remaining time here, because it owns the centre instead.
    private var statusRow: some View {
        HStack(spacing: 3) {
            if focus == .rendering {
                if isPhotoMode || photoFreeBytes != nil {
                    Text(capacityText).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                } else { remainingTime(fontSize: 11) }
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
        .foregroundStyle(.white.opacity(isClassic ? 0.8 : 0.65))
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
            Text(renderActivityLabel)
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
