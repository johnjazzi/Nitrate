#if DEBUG
import Foundation
import Observation
import SwiftUI
import CoreVideo
import CoreGraphics

/// A readback copy of one debug frame, safe to hand across actor boundaries.
struct DebugFrameBitmap: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]
    var milliseconds: Double = 0
    var orientedImage: CGImage?

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

    /// The BGRA8 buffer the renderer produces is directly drawable.
    func makeCGImage() -> CGImage? {
        if let orientedImage { return orientedImage }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
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
    private(set) var message: String?

    private let frame: CVPixelBuffer
    private let renderer: PipelineRenderer?
    private let quarterTurns: Int
    private var renderTask: Task<Void, Never>?

    init(frame: CVPixelBuffer, config: FilmStockConfig, stocks: [FilmStockConfig] = []) {
        self.frame = frame
        self.quarterTurns = CameraFrozenFrameOrientationPolicy.quarterTurns(in: frame)
        self.config = config
        self.stocks = stocks.isEmpty ? [config] : stocks
        self.parameters = PipelineRenderer.DebugFrameParameters(config: config)
        self.renderer = try? PipelineRenderer()
        if renderer == nil { message = "Metal pipeline unavailable." }
        scheduleRender()
    }

    /// Grade the frozen frame with a different stock. Every dial is re-seeded
    /// from the new stock so the sheet lands on that stock's shipping look.
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

    /// Each debug section is collapsible; all start expanded so the sheet reads
    /// exactly as before until the user taps a header.
    @State private var grainExpanded = true
    @State private var halationExpanded = true
    @State private var glowExpanded = true

    init(viewModel: DebugFrameViewModel,
         onPreviewStockOutline: @escaping () -> Void = {},
         hintDiagnostics: StockSelectorHintDiagnostics? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onPreviewStockOutline = onPreviewStockOutline
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
                        VStack(alignment: .leading, spacing: 20) {
                            stockSection
                            realizedValues
                            hintPreviewSection
                            grainSection
                            halationSection
                            glowSection
                            debugControlsSection
                        }
                        .padding()
                    }
                }
            }
            .onChange(of: previewAspect) { _, _ in resetZoom() }
            .navigationTitle("Debug · Single Frame")
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
                .font(.caption2.monospacedDigit().bold())
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
                .font(.caption2)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Stock").font(.headline)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Realized").font(.caption.bold())
            Text(String(format: "footprint %.3f · amount %.3f · gauge amp %.2f",
                        viewModel.parameters.realizedFootprint,
                        viewModel.parameters.realizedAmount,
                        viewModel.parameters.gaugeAmplitude))
                .font(.caption.monospacedDigit())
            Text(String(format: "halation radius %.4f of width · glow %.3f",
                        viewModel.parameters.halationRadiusFraction,
                        viewModel.parameters.glowStrength))
                .font(.caption.monospacedDigit())
            // Truthful statement of the render order this sheet drives: halation
            // is added to the scene-linear source and re-encoded to Apple Log 2
            // BEFORE the stock LUT; glow is a post-LUT graded-luminance bloom.
            Text("Order: halation (scene-linear, pre-LUT) → LUT + contrast → glow → grain")
                .font(.caption2).foregroundStyle(.secondary)
            if let message = viewModel.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else {
                Text(String(format: "render %.0f ms", viewModel.lastRenderMilliseconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// DEBUG-only affordances that reach past this frozen frame: a one-shot
    /// preview of the stock-selector outline, and the hint's decision snapshot.
    private var hintPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stock hint").font(.headline)
            Button {
                // Dismiss first; the screen fires the outline once the sheet is
                // gone, so it is never painted behind this sheet.
                onPreviewStockOutline()
                dismiss()
            } label: {
                Label("Preview stock outline", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let hintDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hint diagnostics (snapshot at open)")
                        .font(.caption.bold())
                    ForEach(hintDiagnostics.lines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("A frozen snapshot taken when this sheet opened, not a live "
                     + "readout. The scene figure is the Gray-World estimate and "
                     + "does not reliably identify a subject's colour.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Switches for the on-screen debug affordances. Mirrored in Settings, so
    /// hiding the DEBUG button cannot strand this sheet.
    private var debugControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug controls")
                .font(.headline)
            Toggle("Show DEBUG button", isOn: $showsDebugButton)
            Toggle("Show FAULT test button", isOn: $showsFaultButton)
            Text("FAULT previews the recording-failure overlay. "
                 + "The same switches are in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var grainSection: some View {
        DebugCollapsibleSection(title: "Grain", isExpanded: $grainExpanded) {
            labelled("Print gauge — re-seeds size and presence") {
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// One collapsible debug section: a tappable header with a chevron that rotates
/// to show its expanded state. All sections start expanded so the sheet reads
/// exactly as before until the user taps a header to collapse it — which lets
/// Grain be tucked away while the Halation controls and the preview stay on
/// screen together.
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
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}
#endif
