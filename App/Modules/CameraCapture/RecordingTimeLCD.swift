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

/// Shared compact queue/capacity face for both finishes. The parent owns its
/// flat or beveled well and transient result border; the icon and hundredths
/// readout share one layout, status source and full-size queue action.
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
    /// Classic's headline and activity words. Minimal draws no words at all.
    var renderActivityLabel: String { isSavingPhoto ? "SAVING" : "RENDERING" }
    var headlineText: String {
        if focus == .recording { return "RECORDING" }
        if focus == .rendering, isRenderingPhoto { return "PHOTO" }
        return isPhotoMode || photoFreeBytes != nil ? "FREE SPACE" : "REC LEFT"
    }

    /// Classic's plate readout, unchanged: free space to one decimal.
    var capacityText: String {
        guard let photoFreeBytes else { return "-- GB" }
        return String(format: "%.1f GB", Double(max(0, photoFreeBytes)) / 1_000_000_000)
    }

    /// Minimal's one readout line: the capacity of the current medium.
    ///
    /// Photo reports free space in whole gigabytes; Video reports the estimated
    /// take in whole minutes. Nothing else is printed — no caption, no remaining
    /// time beside a capacity, no queue word.
    var minimalReadoutText: String {
        if isPhotoMode || photoFreeBytes != nil { return minimalCapacityText }
        return minimalRemainingText
    }

    var minimalCapacityText: String {
        decimalCapacity(photoFreeBytes.map { Double(max(0, $0)) / 1_000_000_000 }, unit: "GB")
    }

    var minimalRemainingText: String {
        decimalCapacity(estimatedSeconds.map { $0 / 60 }, unit: "min")
    }

    /// Hundredths, truncated rather than rounded up: never promise extra space
    /// or recording time. Reject invalid/absurd estimates before multiplication.
    private func decimalCapacity(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) / 100 else { return "-- \(unit)" }
        return String(format: "%.2f %@", (value * 100).rounded(.down) / 100, unit)
    }

    private var focus: RecordingTimeLCDFocus {
        .resolve(isRecording: isRecording, isStopping: isStopping, isProcessing: queueStatus.isProcessing)
    }

    private var isClassic: Bool { uiStyle == .classic }

    /// The smallest this face is ever offered as a tap target. The whole LCD is
    /// the queue action, so its touch area is never a glyph-sized sub-target.
    static let minimumTouchSize: CGFloat = 44

    /// Minimal's queue mark: one large glyph, big enough to read as the action
    /// over bright footage without a word beside it.
    static let queueGlyphSize: CGFloat = 22

    /// Minimal's readout line. One size for both media, so switching between
    /// Photo and Video never resizes the face.
    static let minimalReadoutSize: CGFloat = 12

    /// The small semantic marks worn by the Minimal glyph.
    static let badgeGlyphSize: CGFloat = 11
    static let tallyDotSize: CGFloat = 6

    var body: some View {
        presentation
            .frame(minWidth: Self.minimumTouchSize, minHeight: Self.minimumTouchSize)
            .contentShape(Rectangle())
    }

    private var presentation: some View { minimalFace }

    // MARK: - Minimal

    /// One centred column: the mark, then the single capacity line. It hugs its
    /// ink — the bar puts the well behind it and the flexible frame outside it —
    /// so the plate is never a panel the size of the whole slot.
    private var minimalFace: some View {
        VStack(spacing: 4) {
            minimalMark
            Text(minimalReadoutText)
                .font(NitrateTypography.font(size: Self.minimalReadoutSize)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: CameraControlGeometry.leftWidth)
    }

    /// The queue glyph, or the render ring while a job is in flight. Both wear
    /// the same corner marks, so a take, a failure, a save and low storage read
    /// at a glance without a word being added to the face.
    @ViewBuilder
    private var minimalMark: some View {
        ZStack {
            if showsRenderingActivity {
                if queueStatus.shouldAnimateRendering(reduceMotion: reduceMotion) {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.2) / 1.2
                        loadingRing(rotation: phase * 360)
                    }
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                } else {
                    loadingRing(rotation: 0)
                        .accessibilityHidden(true)
                }
            } else {
                Image(systemName: "list.bullet")
                    // Sized by the same type scale as the app's text; no system
                    // font family and no weight override, which a custom family
                    // cannot apply.
                    .font(NitrateTypography.font(size: Self.queueGlyphSize))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Self.queueGlyphSize, height: Self.queueGlyphSize)
        .overlay(alignment: .topLeading) { minimalTally }
        .overlay(alignment: .topTrailing) { minimalCount }
        .accessibilityHidden(true)
    }

    /// A confirmed, still-live take: a red tally dot on the mark's corner.
    @ViewBuilder
    private var minimalTally: some View {
        if focus == .recording {
            Circle()
                .fill(.red)
                .frame(width: Self.tallyDotSize, height: Self.tallyDotSize)
                .offset(x: -2, y: -2)
        }
    }

    /// Outstanding renders. A small count badge, not a caption; it disappears at
    /// zero so the face stays a single queue action when the queue is empty.
    @ViewBuilder
    private var minimalCount: some View {
        if let count = queueStatus.countText {
            Text(count)
                .font(NitrateTypography.font(size: 8).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .background {
                    Capsule().fill(.black.opacity(0.6))
                }
                .offset(x: 6, y: -4)
        }
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


/// One shared cue for both finishes. A confirmed success scans down the border,
/// pops the full outline, then fades; warnings retain a nonlinear red pulse.
struct CameraQueueAttentionOutline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hasIssue: Bool
    let successAt: Date?

    var body: some View {
        Group {
            if hasIssue || successAt != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSince(successAt ?? .distantPast))
                    let clock = timeline.date.timeIntervalSinceReferenceDate
                    if hasIssue {
                        let wave = (1 - cos(clock * 2 * .pi / 1.92)) / 2
                        let pulse = reduceMotion ? 1 : 0.18 + 0.82 * pow(wave, 4)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.red, lineWidth: 1.5)
                            .opacity(pulse)
                    } else if reduceMotion {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.green, lineWidth: 1.5)
                            .opacity(min(1, max(0, (1.1 - elapsed) / 0.3)))
                    } else {
                        successBorder(elapsed: elapsed)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func successBorder(elapsed: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let progress = min(1, max(0, elapsed / 0.72))
        return GeometryReader { geometry in
            let bandHeight = max(18, geometry.size.height * 0.45)
            let centerY = -bandHeight / 2 + (geometry.size.height + bandHeight) * progress
            if elapsed < 0.72 {
                // The scan stays on the border; the centre is never filled.
                shape.strokeBorder(Color.green, lineWidth: 2)
                    .mask {
                        LinearGradient(colors: [.clear, .white, .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: geometry.size.width, height: bandHeight)
                            .position(x: geometry.size.width / 2, y: centerY)
                    }
            } else {
                let pop = max(0, 1 - abs(elapsed - 0.80) / 0.08)
                let fade = min(1, max(0, (1.1 - elapsed) / 0.24))
                shape.strokeBorder(Color.green, lineWidth: 1.5 + pop)
                    .scaleEffect(1 + 0.045 * pop)
                    .opacity(fade)
            }
        }
    }
}
