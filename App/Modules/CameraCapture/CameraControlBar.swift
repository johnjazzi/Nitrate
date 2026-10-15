import SwiftUI

/// Compact stock/status column, screen-centred REC, and persistent exposure controls.
///
/// Split out of `ContentView` so the screen stays inside the file-length limit.
/// The top toolbar owns settings and the manual-controls popover; this bar
/// owns the shooting controls and remaining-recording-time readout.
struct CameraControlBar: View {
    @Environment(\.cameraDeviceOrientation) private var orientation
    private let controlFaceSize: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives `.sensoryFeedback`; bumped on every REC tap so the press is felt
    /// immediately instead of when capture reports it started.
    @State private var recordFeedbackTrigger = 0
    @State private var recordFeedback: RecordFeedback = .start
    /// The pressed face springs back a beat after the finger lands, so the press
    /// reads as a physical button rather than a state that appeared on its own.
    /// Generation-guarded so rapid taps cannot cross-wire the animation.
    @State private var isUnclicked = false
    @State private var pressGeneration = 0
    let cameraViewModel: CameraViewModel
    let renderQueueViewModel: RenderQueueViewModel
    let selectedStock: FilmStockConfig?
    let currentISO: Float
    let selectedGauge: PrintGauge
    let onShowQueueSheet: () -> Void
    let onShowStockSheet: () -> Void

    var body: some View {
        CameraShootingLayout() {
            selectorRow
            storageIndicator
            recordButton
            exposureControl.frame(width: CameraControlGeometry.exposureWidth)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Left selector row

    private var selectorRow: some View {
        HStack(spacing: 6) {
            stockControl(faceSize: controlFaceSize)
                .frame(width: 52, height: 52)
            if selectedStock != nil {
                CameraGaugeLabel(text: selectedGauge.displayName,
                                 rotationDegrees: CameraGlyphRotation.degrees(for: orientation))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Stock selector

    /// Active stock (or the stock picker when none is chosen yet). Lives in the
    /// leading slot of the selector row.
    private func stockControl(faceSize: CGFloat) -> some View {
        Group {
            if let stock = selectedStock {
                stockChip(stock, faceSize: faceSize)
            } else {
                Button {
                    onShowStockSheet()
                } label: {
                    Image(systemName: "film").font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: faceSize, height: faceSize)
                }
                .buttonStyle(CameraRaisedButtonStyle())
            }
        }
        .cameraRotatingControl()
    }

    /// Duotone stripe card with ISO + D/T badge overlaid in black.
    /// Five horizontal slices fill the complete button face: 1,2,5 are primary;
    /// 3,4 are secondary.
    private func stockChip(_ stock: FilmStockConfig, faceSize: CGFloat) -> some View {
        Button {
            onShowStockSheet()
        } label: {
            CameraFilmStockFace(primary: stock.primaryColor, secondary: stock.secondaryColor,
                                isoLight: "\(Int(currentISO))\(stock.lightType)", faceSize: faceSize)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: stock.primaryColor))
    }

    // MARK: - Exposure control (dual mode)

    /// The live meter and setting share the existing 92pt column: 28pt meter,
    /// 56pt ruler, and two 4pt rims. The footprint stays clear of centred REC
    /// and the left queue/remaining-time column even on a 320pt-wide phone.
    private var exposureControl: some View {
        HStack(alignment: .top, spacing: 0) {
            ExposureIndicatorView(
                meteredEV: cameraViewModel.liveExposureTargetOffset,
                targetEV: cameraViewModel.isManualExposure ? 0 : cameraViewModel.liveExposureBias,
                isManual: cameraViewModel.isManualExposure,
                isAvailable: cameraViewModel.hasExposureMeter
            )
            exposureSetting
                .frame(width: 56)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .modifier(CameraRaisedSurface(cornerRadius: 14))
    }

    /// One setting, two modes. Auto drives the scene's auto-exposure target bias
    /// (EV); manual drives the ISO chooser. Long-press toggles between them.
    private var exposureSetting: some View {
        VStack(spacing: 6) {
            Text(exposureReadout)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 14)
                .foregroundStyle(.white.opacity(0.9))
                .cameraUpright()

            if cameraViewModel.isManualExposure {
                // Match EV's 12pt detents and tick geometry. Logarithmic ISO
                // travel keeps each nominal 1/3 stop equally reachable.
                RulerSlider(
                    value: isoBinding,
                    range: isoSliderRange,
                    step: isoFineStep,
                    pointsPerStep: CGFloat(RulerScale.detentTravel),
                    majorValues: isoMajorValues,
                    tickLabel: { "\(Int($0.rounded()))" },
                    scale: isoScale,
                    ladder: isoLadder,
                    tint: .yellow,
                    length: 120
                )
            } else {
                // Ruler rather than a 1:1 slider: EV compensation needs
                // repeatable 0.1 EV detents, with 12pt of travel per tick.
                RulerSlider(
                    value: evBiasBinding,
                    range: evBiasSliderRange,
                    step: 0.1,
                    pointsPerStep: CGFloat(RulerScale.detentTravel),
                    tint: .orange,
                    length: 120
                )
                .disabled(!cameraViewModel.isExposureBiasAvailable)
                .opacity(cameraViewModel.isExposureBiasAvailable ? 1 : 0.4)
            }

            Text(cameraViewModel.isManualExposure ? "ISO" : "EV")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .cameraUpright()
        }
        .contentShape(Rectangle())
        // Simultaneous so the whole control stays hittable: an exclusive
        // long-press would never fire over the slider track, which is the
        // widest touch target in this stack.
        // Cancel a moving press before it reaches the first 6pt detent
        // midpoint; otherwise a slow adjustment can replace the active ruler.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 3).onEnded { _ in
                cameraViewModel.toggleManualExposure()
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cameraViewModel.isManualExposure ? "Manual ISO" : "Auto exposure bias")
        .accessibilityHint("Long-press to switch between auto and manual exposure")
        .accessibilityAction(named: Text(cameraViewModel.isManualExposure
                                        ? "Switch to auto exposure"
                                        : "Switch to manual exposure")) {
            cameraViewModel.toggleManualExposure()
        }
    }

    /// "+0.0" / "-1.3" style auto-exposure bias readout.
    private var exposureReadout: String {
        if cameraViewModel.isManualExposure {
            return "ISO \(Int(cameraViewModel.liveISO))"
        }
        return String(format: "%+.1f", cameraViewModel.liveExposureBias)
    }

    private var evBiasSliderRange: ClosedRange<Double> {
        let range = cameraViewModel.exposureBiasRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var isoSliderRange: ClosedRange<Double> {
        let range = cameraViewModel.session.isoRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    /// The 1/3-stop ISO values reachable on the active device.
    private var isoLadder: [Double] {
        ISOLadder.values(in: isoSliderRange)
    }

    /// Full stops within the reachable ladder, i.e. the labelled ticks.
    private var isoMajorValues: Set<Double> {
        Set(isoLadder.filter { ISOLadder.fullStops.contains($0) })
    }

    /// Fallback detent size for the (unused while `ladder` is set) `step`
    /// parameter, kept non-zero so the accessibility path stays sane.
    private var isoFineStep: Double { 25 }

    /// 36pt per exposure stop = 12pt per nominal 1/3-stop detent.
    private var isoScale: RulerScale {
        .logarithmic(pointsPerStop: RulerScale.detentTravel * 3)
    }

    /// Binding for the EV-bias slider.
    private var evBiasBinding: Binding<Double> {
        Binding(
            get: { Double(cameraViewModel.liveExposureBias) },
            set: { cameraViewModel.setExposureBias(Float($0)) }
        )
    }

    /// Binding for the manual-ISO ruler.
    private var isoBinding: Binding<Double> {
        Binding(
            get: { Double(cameraViewModel.manualISO) },
            set: { cameraViewModel.setManualISO(Float($0)) }
        )
    }

    /// Immediate acknowledgement for a REC tap.
    ///
    /// Capture cannot confirm a take started until the session queue, the
    /// custom-exposure settle and the asset writer have all run, so waiting for
    /// that round trip made the button feel unresponsive. The press is
    /// acknowledged here, on the tap itself.
    private enum RecordFeedback: Equatable {
        case start
        case stop

        var sensory: SensoryFeedback {
            switch self {
            case .start: .impact(weight: .medium, intensity: 1)
            case .stop: .impact(weight: .heavy, intensity: 1)
            }
        }
    }

    private var recordPresentation: RecordButtonPresentation {
        RecordButtonPresentationPolicy.presentation(
            isRecording: cameraViewModel.isRecording,
            isStarting: cameraViewModel.isStartingRecording,
            isStopping: cameraViewModel.isStoppingRecording
        )
    }

    private var recordButton: some View {
        let presentation = recordPresentation
        let action = RecordButtonPresentationPolicy.action(for: presentation)
        return Button {
            guard action != .none else { return }
            recordFeedback = action == .start ? .start : .stop
            recordFeedbackTrigger &+= 1
            animateUnclick()
            if action == .start {
                cameraViewModel.startRecording()
            } else {
                cameraViewModel.stopRecording()
            }
        } label: {
            recordFace(presentation)
        }
        .buttonStyle(.plain)
        .disabled(!RecordButtonPresentationPolicy.isEnabled(isSpaceCritical: cameraViewModel.isSpaceCritical,
                                                           presentation: presentation))
        .sensoryFeedback(trigger: recordFeedbackTrigger) { _, _ in recordFeedback.sensory }
        .accessibilityLabel(RecordButtonPresentationPolicy.accessibilityLabel(for: presentation))
    }

    /// Shared circular plunger: quiet washed red in every state, no bezel slab.
    private func recordFace(_ presentation: RecordButtonPresentation) -> some View {
        RecordPlungerFace(presentation: presentation, isPressed: isUnclicked,
                          rotationDegrees: CameraGlyphRotation.degrees(for: orientation))
    }

    /// Immediate 2.5pt depression, released at the established 100ms unclick.
    /// The same generation guard prevents a rapid cancel from releasing a newer tap.
    private func animateUnclick() {
        pressGeneration &+= 1
        let generation = pressGeneration
        isUnclicked = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(RecordButtonTimingPolicy.unclickDelay))
            guard generation == pressGeneration else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isUnclicked = false }
        }
    }

    private var queueStatus: CameraStatusPresentation {
        let latest = renderQueueViewModel.currentSessionResults.first
        return CameraStatusPresentation(
            outstandingCount: renderQueueViewModel.outstandingCount,
            pendingCount: renderQueueViewModel.pendingCount,
            isProcessing: renderQueueViewModel.isProcessing,
            failedCount: renderQueueViewModel.currentSessionFailures.count,
            errorMessage: renderQueueViewModel.rendererErrorMessage,
            latestResultCompleted: latest?.status == .completed,
            latestResultSavedToPhotos: latest?.outputSavedToPhotos
        )
    }

    private var isStorageLow: Bool {
        cameraViewModel.hasStorageSnapshot && cameraViewModel.freeSpaceBytes < 1_000_000_000
    }

    private var storageIndicator: some View {
        CameraRotatingSlot(rotationDegrees: CameraGlyphRotation.degrees(for: orientation)) {
            Button(action: onShowQueueSheet) {
                RecordingTimeLCD(
                    estimatedSeconds: estimatedRemainingSeconds,
                    isStorageLow: isStorageLow,
                    queueStatus: queueStatus
                )
            }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage, render queue, and estimated recording time remaining")
        .accessibilityValue("\(estimatedTimeText). \(freeSpaceText) free. "
                            + "\(isStorageLow ? "Low storage. " : "")\(queueStatus.accessibilityDescription)")
        .accessibilityHint("Tap for storage and render queue details, video playback, sharing, and retry controls.")
        }
    }

    private var estimatedTimeText: String {
        guard estimatedRemainingSeconds != nil else { return "Unavailable" }
        let text = RecordingTimeLCD.timeText(for: estimatedRemainingSeconds)
        return text == "--:--" ? "Unavailable" : text
    }

    private var freeSpaceText: String {
        guard cameraViewModel.hasStorageSnapshot else { return "Unavailable" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cameraViewModel.freeSpaceBytes)
    }

    private var estimatedRemainingSeconds: TimeInterval? {
        guard cameraViewModel.hasStorageSnapshot else { return nil }
        return CameraStorageEstimatePolicy.remainingSeconds(
            freeBytes: cameraViewModel.freeSpaceBytes,
            criticalReserveBytes: CameraViewModel.criticalSpaceThreshold,
            videoBitRate: DeliverySettings.averageBitRate,
            audioBitRate: DeliverySettings.aacAverageBitRate
        )
    }
}

/// A rotated (vertical) slider. `length` is the on-screen height of the track;
/// the caller's binding performs the write-through, so no extra action is needed.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    var length: CGFloat = 140

    var body: some View {
        Slider(value: $value, in: range, step: step)
            .tint(tint)
            .frame(width: length, height: 26)
            .rotationEffect(.degrees(-90))
            .frame(width: 26, height: length)
    }
}
