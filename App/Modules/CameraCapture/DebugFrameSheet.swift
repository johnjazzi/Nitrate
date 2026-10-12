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
    private var renderTask: Task<Void, Never>?

    init(frame: CVPixelBuffer, config: FilmStockConfig, stocks: [FilmStockConfig] = []) {
        self.frame = frame
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
                                          parameters: parameters, renderer: renderer)
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
              var bitmap = DebugFrameBitmap(pixelBuffer: result.pixelBuffer) else { return nil }
        bitmap.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return bitmap
    }
}

/// Debug-only sheet: the frozen frame re-rendered live, with grain / halation /
/// glow sliders. Kept out of the shipping look controls; dismisses with Done.
struct DebugFrameSheet: View {
    @State private var viewModel: DebugFrameViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: DebugFrameViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    stockSection
                    realizedValues
                    grainSection
                    halationSection
                    glowSection
                }
                .padding()
            }
            .navigationTitle("Debug · Single Frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - Sections

    private var preview: some View {
        Group {
            if let image = viewModel.image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 200)
                    .overlay { ProgressView() }
            }
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
            if let message = viewModel.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else {
                Text(String(format: "render %.0f ms", viewModel.lastRenderMilliseconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var grainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grain").font(.headline)
            labelled("Print gauge — owns grain size and presence") {
                Picker("Gauge", selection: gaugeBinding) {
                    ForEach(PrintGauge.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            labelled(String(format: "Edge boost %.2f", viewModel.parameters.edgeBoostMultiplier)) {
                Slider(value: float({ viewModel.parameters.edgeBoostMultiplier },
                                    { viewModel.parameters.edgeBoostMultiplier = $0 }),
                       in: 0...3, step: 0.05)
            }
        }
    }

    private var halationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Halation").font(.headline)
            labelled(String(format: "Strength %.2f", viewModel.parameters.halationStrength)) {
                Slider(value: float({ viewModel.parameters.halationStrength },
                                    { viewModel.parameters.halationStrength = $0 }),
                       in: 0...1, step: 0.01)
            }
            labelled(String(format: "Radius fraction %.4f", viewModel.parameters.halationRadiusFraction)) {
                Slider(value: float({ viewModel.parameters.halationRadiusFraction },
                                    { viewModel.parameters.halationRadiusFraction = $0 }),
                       in: 0.004...0.05, step: 0.001)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Glow").font(.headline)
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

    /// The gauge is the single grain control: changing it moves both footprint
    /// and presence, so nothing else needs re-seeding.
    private var gaugeBinding: Binding<PrintGauge> {
        Binding(
            get: { viewModel.parameters.gauge },
            set: { gauge in
                viewModel.parameters.gauge = gauge
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
#endif
