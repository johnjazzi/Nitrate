import SwiftUI

/// Compact stock/status column, screen-centred REC, and persistent exposure controls.
///
/// Split out of `ContentView` so the screen stays inside the file-length limit.
/// The top toolbar owns settings and the manual-controls popover; this bar
/// owns the shooting controls and remaining-recording-time readout.
struct CameraControlBar: View {
    @Environment(\.cameraDeviceOrientation) private var orientation
    private let controlFaceSize: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The persisted face choice. Resolved through `RecordButtonAppearance` so
    /// an unknown or missing value keeps the classic plunger; the same key and
    /// default are used by the Settings picker.
    @AppStorage(RecordButtonAppearance.preferenceKey)
    private var recordButtonAppearance = RecordButtonAppearance.classic.rawValue
    /// True only while the exposure control is being held, whether or not the
    /// press has reached the long-press threshold. `LongPressGesture` feeds it
    /// through `.updating`, so the expanding acknowledgement starts during the
    /// hold rather than at the moment the mode flips, and SwiftUI resets it
    /// automatically on release or cancellation — no mode change, no haptic.
    @GestureState private var isExposureHolding = false
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
    /// One brief outline around the whole stock-selector well, a discoverability
    /// hint only. It adds no layout or hit target: the ring is a non-hit-testing
    /// overlay and never repeats.
    let showsStockHint: Bool
    /// Horizontal inset around the shooting bar. The alignment pass passes a
    /// smaller value so the outer controls line up with the viewfinder edges;
    /// 16 keeps the original spacing when the caller omits it.
    var horizontalInset: CGFloat = 16

    var body: some View {
        CameraShootingLayout() {
            selectorRow
            storageIndicator
            recordButton
            exposureControl.frame(width: CameraControlGeometry.exposureWidth)
        }
        .padding(.horizontal, horizontalInset)
    }

    // MARK: - Left selector row

    /// Stock and gauge share the recessed well that fills the lower third of the
    /// column. The 44pt frame keeps the stock control a full-size tap target
    /// inside the well's own padding.
    private var selectorRow: some View {
        HStack(spacing: 4) {
            stockControl(faceSize: controlFaceSize)
                .frame(width: 44, height: 44)
            if selectedStock != nil {
                CameraGaugeLabel(gauge: selectedGauge,
                                 rotationDegrees: CameraGlyphRotation.degrees(for: orientation))
            }
        }
        .cameraControlWell(horizontalPadding: 4)
        .overlay {
            StockSelectorHintOutline(isVisible: showsStockHint)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
                    Image(systemName: "film").font(NitrateTypography.font(.title3))
                    .foregroundStyle(.white)
                    .frame(width: faceSize, height: faceSize)
                    .frame(minWidth: 44, minHeight: 44)
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
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(CameraRaisedButtonStyle(faceColor: stock.primaryColor))
    }

    // MARK: - Exposure control (dual mode)

    /// The live meter and setting share the compact 84pt column: 28pt meter,
    /// 48pt ruler, and two 4pt rims. The footprint stays clear of centred REC
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
                .frame(width: 48)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .modifier(CameraInsetSurface())
        .contentShape(Rectangle())
        // Visible hold acknowledgement: a small spring expansion the instant the
        // finger lands, springing back on release or cancellation. Reduce Motion
        // gets a steady outline instead of a zoom, so the hold stays visible
        // without scale movement. Only a small transform and a non-layout
        // overlay are applied; columns and touch targets are unchanged.
        .scaleEffect(reduceMotion ? 1 : (isExposureHolding ? 1.07 : 1))
        .overlay {
            RoundedRectangle(cornerRadius: CameraControlBorder.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .opacity(reduceMotion && isExposureHolding ? 1 : 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                                : .spring(response: 0.28, dampingFraction: 0.62),
                   value: isExposureHolding)
        // Simultaneous so the whole control stays hittable: an exclusive
        // long-press would never fire over the slider track, which is the
        // widest touch target in this stack.
        // Cancel a moving press before it reaches the first 6pt detent
        // midpoint; otherwise a slow adjustment can replace the active ruler.
        // `.updating` publishes the held state while the press is still being
        // detected — not only once it reaches the threshold — and SwiftUI clears
        // it on release or cancellation, so the expansion tracks the finger and
        // a dragged/cancelled press never changes the mode or fires the haptic.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 3)
                .updating($isExposureHolding) { current, state, _ in
                    state = current && exposureHoldEnabled
                }
                .onEnded { _ in
                    guard exposureHoldEnabled else { return }
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
        // Keyed to the committed mode, not to the gesture: the long press and
        // the accessibility action share `toggleManualExposure()`, so one state
        // change is felt once however it was requested. The periodic exposure
        // poll never writes this flag, so polling cannot fire it.
        .sensoryFeedback(trigger: cameraViewModel.isManualExposure) { _, isManual in
            CameraHaptics.prepareForCaptureFeedback()
            return ManualExposureLockFeedback.sensory(isManual: isManual)
        }
        // Measurement anchor only: publishes the exposure column's frame in the
        // shared `cameraCanvas` space so the parent can float the daylight rescue
        // button above it. A background never changes the bar's measured footprint.
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CameraControlBoundsPreference.self,
                    value: ["exposure": geometry.frame(in: .named("cameraCanvas"))]
                )
            }
            .allowsHitTesting(false)
        }
    }

    /// One setting, two modes. Auto drives the scene's auto-exposure target bias
    /// (EV); manual drives the ISO chooser. Long-press toggles between them.
    private var exposureHoldEnabled: Bool {
        !cameraViewModel.isStartingRecording && !cameraViewModel.isRecording
            && !cameraViewModel.isStoppingRecording && !cameraViewModel.isChangingFrameRate
    }

    private var exposureSetting: some View {
        VStack(spacing: 6) {
            Text(exposureReadout)
                .font(NitrateTypography.font(.caption2).monospacedDigit())
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

            // Keep the previous footer's exact font height without its words.
            // This preserves the shooting bar and viewfinder geometry.
            Text(" ")
                .font(NitrateTypography.font(size: 9))
                .accessibilityHidden(true)
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

    /// Committed manual-exposure transition. Taking the ISO lock is the firmer
    /// notch; releasing it back to auto is the softer one, so the two are
    /// distinguishable by feel alone.
    enum ManualExposureLockFeedback {
        static func sensory(isManual: Bool) -> SensoryFeedback {
            isManual ? .impact(flexibility: .rigid, intensity: 0.9)
                     : .impact(flexibility: .soft, intensity: 0.6)
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

    /// The chosen face. Both share the 84pt footprint, the press feedback and
    /// the state machine owned by `RecordButtonPresentationPolicy`; only the
    /// drawn appearance differs.
    @ViewBuilder
    private func recordFace(_ presentation: RecordButtonPresentation) -> some View {
        switch RecordButtonAppearance.resolved(recordButtonAppearance) {
        case .classic:
            // Shipping circular plunger: quiet washed red in every state, no
            // bezel slab. Its press animation is unchanged.
            RecordPlungerFace(presentation: presentation, isPressed: isUnclicked,
                              rotationDegrees: CameraGlyphRotation.degrees(for: orientation))
        case .modern:
            ModernRecordButtonFace(presentation: presentation, isPressed: isUnclicked,
                                   rotationDegrees: CameraGlyphRotation.degrees(for: orientation),
                                   reduceMotion: reduceMotion)
        }
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
                    queueStatus: queueStatus,
                    isRecording: recordPresentation == .recording,
                    isStopping: cameraViewModel.isStoppingRecording
                )
            }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage, render queue, and estimated recording time remaining")
        .accessibilityValue("\(recordPresentation == .recording ? "Recording. " : "")"
                            + "\(estimatedTimeText). \(freeSpaceText) free. "
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

/// Publishes per-control frames in the shared `cameraCanvas` space. The control bar
/// contributes the exposure column so the parent can float the daylight rescue
/// button above it without altering any measured footprint. Shared with the
/// toolbar and shooting-bar bounds consumed by `ContentView`.
struct CameraControlBoundsPreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
