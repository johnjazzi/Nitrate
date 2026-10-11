import SwiftUI

/// Bottom camera control stack: a selector row (lens pills + exposure) over an
/// action row (queue / record / storage).
///
/// Split out of `ContentView` so the screen stays inside the file-length limit.
/// Division of labour: the top toolbar owns app/stock settings (active stock,
/// gear, imports, exposure readout); this bar owns the shooting controls.
struct CameraControlBar: View {
    let cameraViewModel: CameraViewModel
    let renderQueueViewModel: RenderQueueViewModel
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    let selectedStock: FilmStockConfig?
    let currentISO: Float
    let onSelectLens: (CameraLens) -> Void
    let onShowQueueSheet: () -> Void
    let onShowStockSheet: () -> Void
    let formatDuration: (TimeInterval) -> String

    /// Inline lens-selector expansion. Not a sheet: the expanded selector takes
    /// over the whole row and hides the exposure control. A tap expands it, and
    /// a further tap (on the selector or on a lens) selects and collapses.
    @State private var isLensSelectorExpanded = false

    var body: some View {
        VStack(spacing: 16) {
            selectorRow
            actionRow
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Row 1: lens selector + exposure

    private var selectorRow: some View {
        Group {
            if isLensSelectorExpanded {
                // Expanded: the lens selector takes over the whole row and the
                // other selectors (stock, exposure) are hidden.
                expandedLensSelector
            } else {
                HStack(alignment: .center, spacing: 12) {
                    stockControl
                    Spacer(minLength: 0)
                    lensPills
                    Spacer(minLength: 0)
                    exposureControl
                }
            }
        }
        .frame(height: 128)
    }

    // MARK: - Stock selector

    /// Active stock (or the stock picker when none is chosen yet). Lives in the
    /// leading slot of the selector row, next to the lens pills.
    private var stockControl: some View {
        Group {
            if let stock = selectedStock {
                stockChip(stock)
            } else {
                Button {
                    onShowStockSheet()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "film").font(.title3)
                        Text("Stock").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 48)
                }
            }
        }
    }

    /// Duotone stripe card with ISO + D/T badge overlaid in black.
    /// 5 horizontal slices: 1,2,5 = primary color; 3,4 = secondary.
    private func stockChip(_ stock: FilmStockConfig) -> some View {
        Button {
            onShowStockSheet()
        } label: {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { idx in
                        let isPrimary = idx == 0 || idx == 1 || idx == 4
                        (isPrimary ? stock.primaryColor : stock.secondaryColor)
                            .frame(height: 5)
                    }
                }
                .frame(width: 48, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("\(Int(currentISO))\(stock.lightType)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    /// Focal-length label above the pills, one pill per available lens.
    private var lensPills: some View {
        VStack(spacing: 6) {
            Text("\(selectedLens.focalLengthMM)mm")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 6) {
                ForEach(availableLenses) { lens in
                    Button {
                        expandLensSelector()
                    } label: {
                        Text(lens.zoomLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(lens == selectedLens ? .black : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(lens == selectedLens ? Color.white : Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Expands the lens selector")
    }

    private var expandedLensSelector: some View {
        VStack(spacing: 6) {
            Text("\(selectedLens.focalLengthMM)mm")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 8) {
                ForEach(availableLenses) { lens in
                    Button {
                        selectLensAndCollapse(lens)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: lens.systemImage)
                                .font(.title3)
                            Text(lens.zoomLabel)
                                .font(.caption.weight(.semibold))
                            Text(lens.rawValue)
                                .font(.system(size: 9))
                                .opacity(0.7)
                        }
                        .foregroundStyle(lens == selectedLens ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(lens == selectedLens ? Color.white : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(8)
            .background(.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func expandLensSelector() {
        withAnimation(.easeInOut(duration: 0.2)) { isLensSelectorExpanded = true }
    }

    private func collapseLensSelector() {
        withAnimation(.easeInOut(duration: 0.2)) { isLensSelectorExpanded = false }
    }

    /// Selecting a lens always collapses; tapping the already-selected lens is
    /// the "tap again to close" gesture.
    private func selectLensAndCollapse(_ lens: CameraLens) {
        collapseLensSelector()
        onSelectLens(lens)
    }

    // MARK: - Exposure control (dual mode)

    /// One control, two modes. Auto drives the scene's auto-exposure target bias
    /// (EV); manual drives the ISO chooser. Long-press toggles between them.
    private var exposureControl: some View {
        VStack(spacing: 6) {
            Text(exposureReadout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))

            if cameraViewModel.isManualExposure {
                // Same ruler affordance as EV, so the two modes of this control
                // feel identical — but ISO needs a different travel curve. A
                // linear rate that is comfortable at 100 is unusably slow at
                // 3200, and vice versa. The exponential scale below grows the
                // rate with the value, and the ladder restricts snapping to the
                // standard 1/3-stop ISO sequence so every detent is a real
                // exposure step.
                RulerSlider(
                    value: isoBinding,
                    range: isoSliderRange,
                    step: isoFineStep,
                    pointsPerStep: 8,
                    majorValues: isoMajorValues,
                    tickLabel: { "\(Int($0.rounded()))" },
                    scale: isoScale,
                    ladder: isoLadder,
                    ladderSubdivisions: 3,
                    tint: .yellow,
                    length: 84
                )
            } else {
                // Ruler rather than a 1:1 slider: EV compensation needs
                // deliberate, repeatable 0.1 EV detents, which a track-mapped
                // slider cannot give. 10mm of travel = 0.25 EV, and the ruler
                // snaps to every tick (0.1) with a haptic click — ~153ppi gives
                // roughly 6pt/mm, so 10mm is ~60pt for 2.5 steps.
                RulerSlider(
                    value: evBiasBinding,
                    range: evBiasSliderRange,
                    step: 0.1,
                    pointsPerStep: 24,
                    tint: .orange,
                    length: 84
                )
                .disabled(!cameraViewModel.isExposureBiasAvailable)
                .opacity(cameraViewModel.isExposureBiasAvailable ? 1 : 0.4)
            }

            Text(cameraViewModel.isManualExposure ? "ISO" : "EV")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        // Simultaneous so the whole control stays hittable: an exclusive
        // long-press would never fire over the slider track, which is the
        // widest touch target in this stack.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
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

    /// Equal travel must not mean equal ISO change: the useful rate is fine at
    /// the bottom of the range and coarse at the top. Calibrated to the agreed
    /// feel — roughly 50 ISO per 10mm around 100, and 500 ISO per 10mm by 5000
    /// (~6pt per mm on a typical iPhone, so 10mm ≈ 60pt).
    private var isoScale: RulerScale {
        let pointsPerMillimetre = 6.0
        return .exponential(
            lowValue: 100,
            lowRate: 50 / (10 * pointsPerMillimetre),
            highValue: 5000,
            highRate: 500 / (10 * pointsPerMillimetre)
        )
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

    // MARK: - Row 2: queue + record + storage

    private var actionRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            queueButton.frame(width: 90)
            recordButton.frame(maxWidth: .infinity)
            storageIndicator.frame(width: 90)
        }
        .frame(height: 96)
    }

    private var recordButton: some View {
        Button {
            if cameraViewModel.isRecording {
                cameraViewModel.stopRecording()
            } else {
                cameraViewModel.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(cameraViewModel.isRecording ? .red : .white)
                    .frame(width: 72, height: 72)
                if cameraViewModel.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 82, height: 82)
                }
            }
        }
        .accessibilityLabel(cameraViewModel.isRecording ? "Stop recording" : "Start recording")
        .disabled(cameraViewModel.isSpaceCritical && !cameraViewModel.isRecording)
        .overlay(alignment: .top) {
            if cameraViewModel.isRecording {
                Text(formatDuration(cameraViewModel.recordingDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.8))
                    .clipShape(Capsule())
                    .offset(y: -18)
            }
        }
    }

    private var queueButton: some View {
        VStack(spacing: 2) {
            RenderStatusButton(viewModel: renderQueueViewModel, action: onShowQueueSheet)
            freeSpaceBar.frame(width: 48, height: 3)
        }
        .frame(maxWidth: .infinity)
    }

    /// Remaining free space as a readable amount plus the fill bar.
    private var storageIndicator: some View {
        VStack(spacing: 5) {
            Image(systemName: "internaldrive")
                .font(.caption)
            Text(freeSpaceText)
                .font(.caption2.monospacedDigit())
            freeSpaceBar.frame(width: 56, height: 4)
            Text("Storage").font(.caption2)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private var freeSpaceText: String {
        guard cameraViewModel.freeSpaceBytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cameraViewModel.freeSpaceBytes)
    }

    private var freeSpaceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.15))
                RoundedRectangle(cornerRadius: 1)
                    .fill(cameraViewModel.isSpaceCritical ? Color.red : Color.white.opacity(0.5))
                    .frame(width: max(0, geo.size.width * CGFloat(cameraViewModel.freeSpacePercent)))
            }
        }
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
