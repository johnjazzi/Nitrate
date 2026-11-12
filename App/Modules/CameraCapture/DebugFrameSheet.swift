#if DEBUG
import Foundation
import Observation
import SwiftUI
import CoreVideo
import CoreGraphics
import CoreImage

/// A readback copy of one debug frame, safe to hand across actor boundaries.
struct DebugFrameBitmap: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]
    var milliseconds: Double = 0
    var orientedImage: CGImage?
    /// The source frame's highlight ceiling, in stops above diffuse white.
    var peakStopsAboveWhite: Float?

    init?(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                                count: bytesPerRow * height))
    }

    /// Pass2 emits gamma-2.4 code values, not directly drawable sRGB bytes.
    func makeCGImage() -> CGImage? {
        if let orientedImage { return orientedImage }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        // The linear tag deliberately preserves the encoded numeric channels
        // until the shared output helper performs the one intended gamma decode.
        let encoded = CIImage(bitmapData: Data(pixels), bytesPerRow: bytesPerRow,
                              size: CGSize(width: width, height: height), format: .BGRA8,
                              colorSpace: space)
        return try? FilmOutputDisplayConverter.makeSRGBImage(fromGamma24: encoded)
    }
}

/// Sendable inputs for one off-main debug render.
private struct DebugFrameRenderInput: @unchecked Sendable {
    let frame: CVPixelBuffer
    let config: FilmStockConfig
    let parameters: PipelineRenderer.DebugFrameParameters
    let renderer: PipelineRenderer?
    let quarterTurns: Int
}

/// Drives the debug single-frame sheet: owns the frozen frame, re-renders it
/// through the pipeline as the sliders move, and hands the result to SwiftUI.
@MainActor
@Observable
final class DebugFrameViewModel: Identifiable {
    let id = UUID()
    private(set) var config: FilmStockConfig
    var parameters: PipelineRenderer.DebugFrameParameters
    /// Stocks the sheet can grade the frozen frame with.
    let stocks: [FilmStockConfig]
    private(set) var image: CGImage?
    private(set) var lastRenderMilliseconds: Double = 0
    /// Highlight headroom of the frozen frame, reported beside the halation onset.
    private(set) var peakStopsAboveWhite: Float?
    private(set) var message: String?

    private let frame: CVPixelBuffer
    /// Source width, so the sheet can report the diffusion preset's realized
    /// radius at THIS frame's size instead of the authored 1080p number.
    let sourceWidth: Int
    private let renderer: PipelineRenderer?
    private let quarterTurns: Int
    private var renderTask: Task<Void, Never>?

    init(frame: CVPixelBuffer, config: FilmStockConfig, stocks: [FilmStockConfig] = []) {
        self.frame = frame
        self.quarterTurns = CameraFrozenFrameOrientationPolicy.quarterTurns(in: frame)
        self.sourceWidth = CVPixelBufferGetWidth(frame)
        self.config = config
        self.stocks = stocks.isEmpty ? [config] : stocks
        self.parameters = PipelineRenderer.DebugFrameParameters(config: config)
        self.renderer = try? PipelineRenderer()
        if renderer == nil { message = "Metal pipeline unavailable." }
        scheduleRender()
    }

    /// Grade the processed snapshot with a different stock's video defaults.
    /// Acquisition white balance/ISP processing remain frozen; this is not a
    /// RAW redevelopment or a promise of that stock's delivered Photo appearance.
    func selectStock(_ stock: FilmStockConfig) {
        guard stock.stockId != config.stockId else { return }
        config = stock
        parameters = PipelineRenderer.DebugFrameParameters(config: stock)
        scheduleRender()
    }

    /// Debounced: a slider drag fires many changes, so coalesce them into one GPU
    /// render ~30 ms after the last change and cancel any superseded render.
    func scheduleRender() {
        renderTask?.cancel()
        let input = DebugFrameRenderInput(frame: frame, config: config,
                                          parameters: parameters, renderer: renderer, quarterTurns: quarterTurns)
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            let bitmap = await Task.detached(priority: .userInitiated) {
                Self.render(input)
            }.value
            guard !Task.isCancelled else { return }
            self.apply(bitmap)
        }
    }

    private func apply(_ bitmap: DebugFrameBitmap?) {
        guard let bitmap else {
            message = "Debug frame render failed."
            return
        }
        message = nil
        image = bitmap.makeCGImage()
        lastRenderMilliseconds = bitmap.milliseconds
        peakStopsAboveWhite = bitmap.peakStopsAboveWhite
    }

    private nonisolated static func render(_ input: DebugFrameRenderInput) -> DebugFrameBitmap? {
        guard let renderer = input.renderer else { return nil }
        let start = DispatchTime.now()
        guard let result = renderer.renderDebugFrame(pixelBuffer: input.frame, config: input.config,
                                                     parameters: input.parameters),
              var bitmap = DebugFrameBitmap(pixelBuffer: result.pixelBuffer),
              let image = bitmap.makeCGImage(),
              let oriented = CameraFrozenFrameOrientationPolicy.orient(image, quarterTurns: input.quarterTurns)
        else { return nil }
        bitmap.orientedImage = oriented
        bitmap.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        bitmap.peakStopsAboveWhite = result.peakStopsAboveWhite
        return bitmap
    }
}

/// Debug-only sheet: the frozen frame re-rendered live, with grain / halation /
/// glow sliders. Kept out of the shipping look controls; dismisses with Done.
struct DebugFrameSheet: View {
    @State private var viewModel: DebugFrameViewModel
    @Environment(\.dismiss) private var dismiss
    /// Called when the DEBUG "Preview stock outline" button is tapped: the screen
    /// records the request and this sheet dismisses, then the screen fires the
    /// one-shot outline once dismissal completes — never behind this sheet.
    let onPreviewStockOutline: () -> Void
    let onPreviewFault: () -> Void
    /// Frozen hint decision snapshot, captured when the sheet opened.
    let hintDiagnostics: StockSelectorHintDiagnostics?
    /// Switches for the on-screen debug affordances. Mirrored in Settings, because
    /// this sheet is reachable only from the DEBUG button it can hide.
    @AppStorage(DebugControlPreferences.showsDebugButtonKey) private var showsDebugButton = true
    @AppStorage(DebugControlPreferences.showsFaultButtonKey) private var showsFaultButton = true

    /// Preview zoom/pan. Live values follow the gesture; the `committed` copies
    /// are the baseline the next gesture starts from.
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    private static let maxZoom: CGFloat = 8

    /// Preview geometry. The sheet is a ScrollView; the preview is sized from the
    /// frozen frame's real aspect ratio so a portrait frame is not letterboxed
    /// into a short strip, and the height is capped so the sliders below stay
    /// reachable on a small screen.
    private static let maxPreviewHeight: CGFloat = 420
    /// Neutral aspect used before the first render lands, so the loading box has
    /// a sensible height instead of collapsing.
    private static let fallbackAspect: CGFloat = 4.0 / 3.0

    /// Keep the image visible and reveal only the controls being adjusted.
    @State private var stockExpanded = false
    @State private var hintExpanded = false
    @State private var grainExpanded = false
    @State private var halationExpanded = false
    @State private var diffusionExpanded = false
    @State private var glowExpanded = false
    @State private var realizedExpanded = false
    @State private var debugControlsExpanded = false

    init(viewModel: DebugFrameViewModel,
         onPreviewStockOutline: @escaping () -> Void = {},
         onPreviewFault: @escaping () -> Void = {},
         hintDiagnostics: StockSelectorHintDiagnostics? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onPreviewStockOutline = onPreviewStockOutline
        self.onPreviewFault = onPreviewFault
        self.hintDiagnostics = hintDiagnostics
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Keep the image visible while any effect controls scroll.
                    preview(height: min(Self.maxPreviewHeight,
                                        max(1, geometry.size.height * 0.45),
                                        max(1, geometry.size.width - 32) / previewAspect))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Frozen processed-camera frame · video diagnostics, not a delivered RAW Photo replay.")
                                .font(NitrateTypography.font(.caption2))
                                .foregroundStyle(.secondary)
                            Text("White balance and ISP processing are frozen. Stock changes use video defaults; display is sRGB.")
                                .font(NitrateTypography.font(.caption2))
                                .foregroundStyle(.secondary)
                            stockSection
                            grainSection
                            halationSection
                            diffusionSection
                            glowSection
                            realizedValues
                            debugControlsSection
                            hintPreviewSection
                        }
                        .font(NitrateTypography.font(.caption))
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
            .onChange(of: previewAspect) { _, _ in resetZoom() }
            .navigationTitle("Debug · Processed Frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - Sections

    /// Aspect ratio of the frozen frame currently on screen. Drives both the
    /// preview height and the zoom/pan reset when a differently shaped frame
    /// arrives. Falls back to a neutral ratio while the first render runs.
    private var previewAspect: CGFloat {
        guard let image = viewModel.image, image.height > 0 else { return Self.fallbackAspect }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    private func preview(height: CGFloat) -> some View {
        ZStack {
            if let image = viewModel.image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(pan)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(zoomGesture.simultaneously(with: panGesture))
        .onTapGesture(count: 2) { resetZoom() }
        .overlay(alignment: .bottomTrailing) { zoomBadge }
        .overlay(alignment: .bottomLeading) { zoomHint }
    }

    /// Pinch to zoom. Never below 1:1 — the frame is already fit to the viewport,
    /// so zooming out would only add empty space.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value.magnification, 1), Self.maxZoom)
            }
            .onEnded { _ in
                committedZoom = zoom
                if zoom <= 1.001 { resetZoom() }
            }
    }

    /// Drag to pan, only while zoomed in, so an un-zoomed sheet still scrolls.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: committedPan.width + value.translation.width,
                             height: committedPan.height + value.translation.height)
            }
            .onEnded { _ in
                if zoom > 1 { committedPan = pan } else { resetZoom() }
            }
    }

    @ViewBuilder
    private var zoomBadge: some View {
        if zoom > 1.001 {
            Text(String(format: "%.1fx", zoom))
                .font(NitrateTypography.font(.caption2).monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private var zoomHint: some View {
        if zoom <= 1.001 {
            Text("Pinch to zoom")
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            committedZoom = 1
            pan = .zero
            committedPan = .zero
        }
    }

    private var stockSection: some View {
        DebugCollapsibleSection(title: "Stock", isExpanded: $stockExpanded) {
            Picker("Stock", selection: Binding(
                get: { viewModel.config.stockId },
                set: { id in
                    guard let stock = viewModel.stocks.first(where: { $0.stockId == id }) else { return }
                    viewModel.selectStock(stock)
                }
            )) {
                ForEach(viewModel.stocks, id: \.stockId) { stock in
                    Text(stock.displayName).tag(stock.stockId)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var realizedValues: some View {
        DebugCollapsibleSection(title: "Realized", isExpanded: $realizedExpanded) {
            Text(String(format: "footprint %.3f · amount %.3f · gauge amp %.2f",
                        viewModel.parameters.realizedFootprint,
                        viewModel.parameters.realizedAmount,
                        viewModel.parameters.gaugeAmplitude))
                .font(NitrateTypography.font(.caption).monospacedDigit())
            Text(String(format: "halation radius %.4f of width · glow %.3f",
                        viewModel.parameters.halationRadiusFraction,
                        viewModel.parameters.glowStrength))
                .font(NitrateTypography.font(.caption).monospacedDigit())
            // Truthful statement of the render order this sheet drives: halation
            // is added to the scene-linear source and re-encoded to Apple Log 2
            // BEFORE the stock LUT; glow is a post-LUT graded-luminance bloom.
            Text("Order: diffusion → halation (scene-linear, pre-LUT) → LUT + contrast → glow → grain")
                .font(NitrateTypography.font(.caption2)).foregroundStyle(.secondary)
            if let message = viewModel.message {
                Text(message).font(NitrateTypography.font(.caption)).foregroundStyle(.red)
            } else {
                Text(String(format: "render %.0f ms", viewModel.lastRenderMilliseconds))
                    .font(NitrateTypography.font(.caption2)).foregroundStyle(.secondary)
            }
        }
    }

    /// DEBUG-only affordances that reach past this frozen frame: a one-shot
    /// preview of the stock-selector outline, and the hint's decision snapshot.
    private var hintPreviewSection: some View {
        DebugCollapsibleSection(title: "Tests", isExpanded: $hintExpanded) {
            Button {
                // Dismiss first; the screen fires the outline once the sheet is
                // gone, so it is never painted behind this sheet.
                onPreviewStockOutline()
                dismiss()
            } label: {
                Label("Preview stock outline", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            Button {
                onPreviewFault()
                dismiss()
            } label: {
                Label("Show fault", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            if let hintDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hint status at open")
                        .font(NitrateTypography.font(.caption).bold())
                    ForEach(hintDiagnostics.lines, id: \.self) { line in
                        Text(line)
                            .font(NitrateTypography.font(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Scene estimates can be inaccurate for colored subjects.")
                    .font(NitrateTypography.font(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Switches for the on-screen debug affordances. Mirrored in Settings, so
    /// hiding the DEBUG button cannot strand this sheet.
    private var debugControlsSection: some View {
        DebugCollapsibleSection(title: "Debug controls", isExpanded: $debugControlsExpanded) {
            Toggle("Show DEBUG button", isOn: $showsDebugButton)
            Toggle("Show FAULT test button", isOn: $showsFaultButton)
            Text("FAULT previews the recording-failure overlay. "
                 + "The same switches are in Settings.")
                .font(NitrateTypography.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var grainSection: some View {
        DebugCollapsibleSection(title: "Grain", isExpanded: $grainExpanded) {
            labelled("Print gauge — re-seeds grain and halation") {
                Picker("Gauge", selection: gaugeBinding) {
                    ForEach(PrintGauge.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            labelled(String(format: "Size %.2f  (footprint %.2f)",
                            viewModel.parameters.sizeMultiplier,
                            viewModel.parameters.realizedFootprint)) {
                Slider(value: float({ viewModel.parameters.sizeMultiplier },
                                    { viewModel.parameters.sizeMultiplier = $0 }),
                       in: 0.3...6, step: 0.05)
            }
            labelled(String(format: "Presence %.2f  (amount %.3f)",
                            viewModel.parameters.presenceMultiplier,
                            viewModel.parameters.realizedAmount)) {
                Slider(value: float({ viewModel.parameters.presenceMultiplier },
                                    { viewModel.parameters.presenceMultiplier = $0 }),
                       in: 0...1.5, step: 0.01)
            }
            labelled(String(format: "Edge boost %.2f", viewModel.parameters.edgeBoostMultiplier)) {
                Slider(value: float({ viewModel.parameters.edgeBoostMultiplier },
                                    { viewModel.parameters.edgeBoostMultiplier = $0 }),
                       in: 0...3, step: 0.05)
            }
        }
    }

    private var halationSection: some View {
        DebugCollapsibleSection(title: "Halation", isExpanded: $halationExpanded) {
            labelled(String(format: "Strength %.2f", viewModel.parameters.halationStrength)) {
                Slider(value: float({ viewModel.parameters.halationStrength },
                                    { viewModel.parameters.halationStrength = $0 }),
                       in: 0...8, step: 0.01)
            }
            // One onset per layer, in stops above diffuse white: the level where
            // that layer starts to halate, and the number that can be pasted
            // straight into the stage's constants. Red comes on first — 0 is
            // diffuse white, and the ramp runs from here up to the stage's
            // reference (10x white, 3.32 stops) at an even rate per stop.
            labelled(String(format: "Onset  R %+.2f   G %+.2f   B %+.2f  stops above white",
                            viewModel.parameters.halationRedOnsetStops,
                            viewModel.parameters.halationGreenOnsetStops,
                            viewModel.parameters.halationBlueOnsetStops)) {
                VStack(spacing: 4) {
                    Slider(value: float({ viewModel.parameters.halationRedOnsetStops },
                                        { viewModel.parameters.halationRedOnsetStops = $0 }),
                           in: -6...3.3, step: 0.05)
                    Slider(value: float({ viewModel.parameters.halationGreenOnsetStops },
                                        { viewModel.parameters.halationGreenOnsetStops = $0 }),
                           in: -6...3.3, step: 0.05)
                    Slider(value: float({ viewModel.parameters.halationBlueOnsetStops },
                                        { viewModel.parameters.halationBlueOnsetStops = $0 }),
                           in: -6...3.3, step: 0.05)
                }
            }
            Text(halationReadout)
                .font(NitrateTypography.font(.caption).monospacedDigit())
            labelled(String(format: "Radius fraction %.4f", viewModel.parameters.halationRadiusFraction)) {
                Slider(value: float({ viewModel.parameters.halationRadiusFraction },
                                    { viewModel.parameters.halationRadiusFraction = $0 }),
                       in: 0.0005...0.0030, step: 0.0001)
            }
            labelled(String(format: "Tint  R %.2f   G %.2f   B %.2f",
                            viewModel.parameters.halationTint.x,
                            viewModel.parameters.halationTint.y,
                            viewModel.parameters.halationTint.z)) {
                VStack(spacing: 4) {
                    Slider(value: float({ viewModel.parameters.halationTint.x },
                                        { viewModel.parameters.halationTint.x = $0 }), in: 0...1, step: 0.01)
                    Slider(value: float({ viewModel.parameters.halationTint.y },
                                        { viewModel.parameters.halationTint.y = $0 }), in: 0...1, step: 0.01)
                    Slider(value: float({ viewModel.parameters.halationTint.z },
                                        { viewModel.parameters.halationTint.z = $0 }), in: 0...1, step: 0.01)
                }
            }
        }
    }

    /// The onsets the stage will actually use against what the frame carries.
    ///
    /// Both numbers are stops above diffuse white — the scale the dials are in —
    /// so the comparison is direct. The frame's peak arrives relative to the
    /// frame's own 1.0, and the mask reads the frame through `frameWhiteStops`, so
    /// the peak is shifted by the same offset before the two are put side by side.
    /// Without the two numbers an empty halo is ambiguous: either the dials are
    /// doing nothing or nothing in the frame is bright enough to scatter, and
    /// those need different fixes.
    private var halationReadout: String {
        let onsets = SpatialEffectsStage.halationOnsets(
            authored: SIMD3(viewModel.parameters.halationRedOnsetStops,
                            viewModel.parameters.halationGreenOnsetStops,
                            viewModel.parameters.halationBlueOnsetStops))
        let line = "onset R \(signed(onsets.x)) G \(signed(onsets.y)) B \(signed(onsets.z)) stops"
        guard let peak = viewModel.peakStopsAboveWhite else {
            return "frame peak unmeasured · \(line)"
        }
        let deliveredPeak = peak - SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0)
        let reach = deliveredPeak < onsets.x
            ? " · nothing in the frame reaches the red onset"
            : ""
        return "frame peak \(signed(deliveredPeak)) stops "
            + "(\(fmt(powf(2, peak)))× white, relative to the frame) · \(line)\(reach)"
    }

    private func signed(_ value: Float) -> String { String(format: "%+.2f", value) }

    private func fmt(_ value: Float) -> String { String(format: "%.2f", value) }

    /// Lens diffusion node: the radius ladder plus the blend amount, with the
    /// resolved blur reported at THIS frame's width so the pixel figures mean
    /// something on a 4K capture as well as on a 1080p one.
    private var diffusionSection: some View {
        DebugCollapsibleSection(title: "Diffusion", isExpanded: $diffusionExpanded) {
            labelled("Radius preset — 75 is bypassed for speed") {
                Picker("Radius", selection: presetBinding) {
                    ForEach(DiffusionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
            labelled(String(format: "Amount %.2f", viewModel.parameters.diffusion.amount)) {
                Slider(value: float({ viewModel.parameters.diffusion.amount },
                                    { viewModel.parameters.diffusion.amount = $0 }),
                       in: 0...1, step: 0.01)
            }
            Text(diffusionReadout)
                .font(NitrateTypography.font(.caption).monospacedDigit())
            Text("Each print gauge owns its radius and amount; this section re-seeds from the gauge.")
            Text("Amount = share of scene light taken from the diffused copy (linear mix, so "
                 + "0.50 halves contrast). Radius = how far it spreads, σ = radius / 2.")
            Text("Scene-linear, pre-LUT: softens the light before halation and the stock LUT.")
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(.secondary)
        }
    }

    private var presetBinding: Binding<DiffusionPreset> {
        Binding(
            get: { viewModel.parameters.diffusion.preset },
            set: { preset in
                viewModel.parameters.diffusion.preset = preset
                viewModel.scheduleRender()
            }
        )
    }

    /// What the preset resolves to on this frame. Computed, not measured — the
    /// sheet's total render time already reports the measured cost.
    private var diffusionReadout: String {
        let settings = viewModel.parameters.diffusion
        guard settings.preset.radiusPixels != nil else {
            return settings.preset == .radius75 ? "75 · bypassed, nothing rendered" : "off"
        }
        guard let plan = settings.plan(sourceWidth: viewModel.sourceWidth) else {
            return "amount 0 · node disabled"
        }
        let sigma = plan.sigmaPixels(atSourceWidth: viewModel.sourceWidth)
        let radius = plan.radiusPixels(atSourceWidth: viewModel.sourceWidth)
        return String(format: "%.0f px radius · σ %.2f px · %d level%@ · %d taps/axis",
                      radius, sigma, plan.levels, plan.levels == 1 ? "" : "s", plan.taps)
    }

    private var glowSection: some View {
        DebugCollapsibleSection(title: "Glow", isExpanded: $glowExpanded) {
            labelled(String(format: "Strength %.2f", viewModel.parameters.glowStrength)) {
                Slider(value: float({ viewModel.parameters.glowStrength },
                                    { viewModel.parameters.glowStrength = $0 }),
                       in: 0...1, step: 0.01)
            }
        }
    }

    // MARK: - Helpers

    /// A slider binding that re-renders (debounced) whenever the value changes.
    private func float(_ get: @escaping () -> Float, _ set: @escaping (Float) -> Void) -> Binding<Float> {
        Binding(
            get: get,
            set: { newValue in
                set(newValue)
                viewModel.scheduleRender()
            }
        )
    }

    /// Picking a gauge re-seeds the size and presence dials from its authored
    /// multipliers; the sliders then take over.
    private var gaugeBinding: Binding<PrintGauge> {
        Binding(
            get: { viewModel.parameters.gauge },
            set: { gauge in
                viewModel.parameters.applyGauge(gauge)
                viewModel.scheduleRender()
            }
        )
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NitrateTypography.font(.caption)).foregroundStyle(.secondary)
            content().frame(minHeight: 44)
        }
    }
}

/// Compact disclosure headers retain a full-height touch target.
private struct DebugCollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(NitrateTypography.font(.subheadline).weight(.medium)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(NitrateTypography.font(.footnote).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
            }
        }
    }
}
#endif
