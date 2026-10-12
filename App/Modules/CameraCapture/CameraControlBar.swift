import SwiftUI

/// Bottom camera controls: stock/lenses and queue/record on the left, with the
/// exposure ruler and storage indicator in a persistent right column.
///
/// Split out of `ContentView` so the screen stays inside the file-length limit.
/// Division of labour: the top toolbar owns app/stock settings (active stock,
/// gear, imports, exposure readout); this bar owns the shooting controls.
struct CameraControlBar: View {
    private let controlFaceSize: CGFloat = 44
    private let recordFaceSize: CGFloat = 84
    private let actionRowHeight: CGFloat = 88
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

    @State private var isStorageInfoPresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                selectorRow
                actionRow
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                exposureControl
                storageIndicator
            }
            .frame(width: 92)
        }
        .overlay(alignment: .top) {
            ZStack {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: actionRowHeight)
                    .allowsHitTesting(false)
                recordButton
                    .frame(width: recordFaceSize, height: recordFaceSize)
            }
            .frame(height: actionRowHeight)
                .padding(.top, controlFaceSize + 8)
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $isStorageInfoPresented) {
            CameraStorageInfoSheet(
                freeSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.freeSpaceBytes : nil,
                totalSpaceBytes: cameraViewModel.hasStorageSnapshot ? cameraViewModel.totalSpaceBytes : nil,
                estimatedSeconds: estimatedRemainingSeconds
            )
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Left selector row

    private var selectorRow: some View {
        GeometryReader { geometry in
            let gapWidth = CGFloat(8 + max(availableLenses.count - 1, 0) * 4)
            let itemCount = CGFloat(availableLenses.count + 1)
            let faceSize = min(controlFaceSize, max(28, (geometry.size.width - gapWidth) / itemCount))

            HStack(alignment: .center, spacing: 8) {
                stockControl(faceSize: faceSize)
                lensPills(faceSize: faceSize)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: controlFaceSize)
        }
        .frame(height: controlFaceSize)
    }

    // MARK: - Stock selector

    /// Active stock (or the stock picker when none is chosen yet). Lives in the
    /// leading slot of the selector row, next to the lens pills.
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
    }

    /// Duotone stripe card with ISO + D/T badge overlaid in black.
    /// 5 horizontal slices: 1,2,5 = primary color; 3,4 = secondary.
    private func stockChip(_ stock: FilmStockConfig, faceSize: CGFloat) -> some View {
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
                .frame(width: faceSize, height: faceSize * 0.64)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("\(Int(currentISO))\(stock.lightType)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: faceSize, height: faceSize)
        }
        .buttonStyle(CameraRaisedButtonStyle())
    }

    /// One direct selection tile per available camera, including Front.
    private func lensPills(faceSize: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(availableLenses) { lens in
                Button {
                    onSelectLens(lens)
                } label: {
                    Text(lens == .front ? "Front" : "\(lens.focalLengthMM)mm")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(lens == selectedLens ? .black : .white)
                        .frame(width: faceSize, height: faceSize)
                }
                .buttonStyle(CameraRaisedButtonStyle(
                    faceColor: lens == selectedLens ? .white : Color(red: 0.16, green: 0.17, blue: 0.19),
                    cornerRadius: 6
                ))
                .accessibilityLabel(lens == .front ? "Front camera" : "\(lens.focalLengthMM) millimeter camera")
            }
        }
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
                    length: 120
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
                    length: 120
                )
                .disabled(!cameraViewModel.isExposureBiasAvailable)
                .opacity(cameraViewModel.isExposureBiasAvailable ? 1 : 0.4)
            }

            Text(cameraViewModel.isManualExposure ? "ISO" : "EV")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .modifier(CameraRaisedSurface(cornerRadius: 14))
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

    // MARK: - Left action row: queue + record

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            queueButton.frame(width: controlFaceSize, height: controlFaceSize)
            Spacer(minLength: 0)
        }
        .frame(height: actionRowHeight)
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
                    .frame(width: 40, height: 40)
                if cameraViewModel.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 58, height: 58)
                }
            }
            .frame(width: recordFaceSize, height: recordFaceSize)
        }
        .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 8))
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
        RenderStatusButton(viewModel: renderQueueViewModel, action: onShowQueueSheet)
    }

    private var storageIndicator: some View {
        Button {
            cameraViewModel.updateFreeSpace()
            isStorageInfoPresented = true
        } label: {
            VStack(spacing: 2) {
                Text(estimatedTimeText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("TIME LEFT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
        }
        .buttonStyle(CameraRaisedButtonStyle(
            faceColor: cameraViewModel.hasStorageSnapshot && cameraViewModel.freeSpaceBytes < 1_000_000_000
                ? .red : Color(red: 0.16, green: 0.17, blue: 0.19),
            cornerRadius: 6
        ))
        .accessibilityLabel("Estimated recording time remaining, \(estimatedTimeText)")
        .accessibilityValue("\(freeSpaceText) free")
        .accessibilityHint("Opens storage details")
    }

    private var estimatedTimeText: String {
        guard let seconds = estimatedRemainingSeconds else { return "Unavailable" }
        return formatDuration(seconds)
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
