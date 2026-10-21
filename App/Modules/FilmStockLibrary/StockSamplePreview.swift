import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import SwiftUI
import simd

/// Stock-selector preview: one bundled Apple Log 2 plate per scene, with the selected
/// stock's LUT applied on the GPU.
///
/// The plate ships ungraded so the look can be applied live: a user-supplied cube, a grade
/// tweak or a gauge change updates the preview with no new asset. The LUT lookup matches
/// `cameraPreviewFragment` exactly, so a plate and a live frame grade identically.
///
/// The preview stands in for a full-size render of the same stock and runs the same chain in
/// the same order -- white-balance preparation, the production halation stage, the stock LUT,
/// then gauge grain -- so it needs neither a baked per-stock still nor a second, invented
/// effect shader.
///
/// Plates are the author's RAW photographs converted to Apple Wide Gamut and encoded with
/// the Apple Log curve. They are illustrative, not camera-recorded Apple Log 2 frames.
struct StockSamplePreview: View {
    let stock: FilmStockConfig?
    /// Print gauge, so the preview shows the grain that gauge produces.
    var gauge: PrintGauge?
    @State private var sceneID = ""
    /// The optional magnified crop. The card's frame never changes with it, so the sheet keeps
    /// its height; only the sampled window (and the grain/halation scale) does.
    @State private var isDetail = false
    private static let catalog = Result { try StockSampleCatalog.load() }

    var body: some View {
        switch Self.catalog {
        case .success(let catalog):
            VStack(spacing: 10) {
                // A paged TabView has no intrinsic size: without a definite frame it
                // collapses and no card appears. Give it the plate's 2:3 shape, bounded so
                // the strip below stays reachable on a short phone.
                GeometryReader { proxy in
                    let cardWidth = min(proxy.size.width, 250)
                    pages(catalog)
                        .frame(width: cardWidth, height: cardWidth * 1.5)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 375)
                sceneDots(catalog)
                Text(catalog.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                if !catalog.scenes.contains(where: { $0.id == sceneID }), let first = catalog.scenes.first {
                    sceneID = first.id
                }
            }
        case .failure:
            ContentUnavailableView("Example photos unavailable", systemImage: "photo.on.rectangle.angled",
                                   description: Text("You can still choose a stock and render your recording."))
                .frame(height: 200)
        }
    }

    private func pages(_ catalog: StockSampleCatalog) -> some View {
        TabView(selection: $sceneID) {
            ForEach(catalog.scenes) { scene in
                PlatePage(url: scene.plateURL(directory: catalog.directory),
                          title: scene.title,
                          stockName: stock?.displayName ?? "Neutral",
                          lutName: stock?.lutName ?? "AppleLog2ToRec709.cube",
                          configuration: PreviewConfiguration(stock: stock, gauge: gauge,
                                                              sceneIlluminantKelvin: scene.sceneIlluminantKelvin),
                          isDetail: isDetail,
                          onToggleDetail: { isDetail.toggle() })
                    .padding(.horizontal, 4)
                    .tag(scene.id)
            }
        }
#if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .never))
#endif
        .accessibilityIdentifier("stock.examplePhotos")
    }

    private func sceneDots(_ catalog: StockSampleCatalog) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(catalog.scenes.enumerated()), id: \.element.id) { index, scene in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sceneID = scene.id }
                } label: {
                    Circle()
                        .fill(sceneID == scene.id ? Color.accentColor : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Example photo: \(scene.title)")
                .accessibilityValue("\(index + 1) of \(catalog.scenes.count)")
                .accessibilityAddTraits(sceneID == scene.id ? [.isSelected] : [])
            }
        }
    }
}

/// One page: the plate with this stock's cube applied, plus its caption.
/// Everything the shader needs for one (scene, stock, gauge) combination: the realised grain
/// footprint, the grain presence that gauge carries, the white-balance lock the camera would
/// apply, and the stock's own halation parameters.
struct PreviewConfiguration: Equatable {
    /// Realised grain cell size, in REFERENCE-frame pixels.
    let footprint: Float
    /// Grain presence. The gauge owns it, so 8mm reads coarse and loud and 75mm nearly none.
    let amplitude: Float
    /// Simulates the stock lock's cast with a Bradford transform in linear Apple Wide Gamut,
    /// carrying the locked white onto the assumed scene white.
    let whiteBalance: simd_float3x3
    /// Pre-LUT halation, straight from the stock. Never rescaled here: the 30% total-amount
    /// reduction lives in the catalogs, so applying it again would halve it twice.
    let halationStrength: Float
    /// Base diffusion radius as a fraction of half-resolution width -- already relative to
    /// the frame, so it needs no rescaling for the smaller preview drawable.
    let halationRadiusFraction: Float
    /// Per-layer halation contribution weights (red dominant).
    let halationTint: SIMD3<Float>
    /// Long edge, in pixels, of the render the preview stands in for. Grain is sized in this
    /// frame's pixels so the card shows the grain a full render would, not a magnified copy.
    let referenceLongEdge: Float
    /// Magnification of the optional detail view. 1 shows the whole frame; a larger value shows
    /// a centre crop of it, with the grain and the halation magnified by the same factor rather
    /// than the photo alone.
    let zoom: Float

    /// The 4K delivery frame.
    static let defaultReferenceLongEdge: Float = 3840

    init(footprint: Float, amplitude: Float, whiteBalance: simd_float3x3,
         halationStrength: Float, halationRadiusFraction: Float, halationTint: SIMD3<Float>,
         referenceLongEdge: Float = PreviewConfiguration.defaultReferenceLongEdge,
         zoom: Float = 1) {
        self.footprint = footprint
        self.amplitude = amplitude
        self.whiteBalance = whiteBalance
        self.halationStrength = halationStrength
        self.halationRadiusFraction = halationRadiusFraction
        self.halationTint = halationTint
        self.referenceLongEdge = referenceLongEdge
        self.zoom = zoom
    }

    init(stock: FilmStockConfig?, gauge: PrintGauge?, sceneIlluminantKelvin: Float) {
        guard let stock else {
            self.init(footprint: 0, amplitude: 0, whiteBalance: matrix_identity_float3x3,
                      halationStrength: 0, halationRadiusFraction: 0,
                      halationTint: SIMD3(repeating: 0))
            return
        }
        let effectiveGauge = gauge ?? stock.effectivePrintGauge
        self.init(
            footprint: GrainModel.effectiveSize(stockGrainSize: stock.grainSize, gauge: effectiveGauge),
            amplitude: GrainModel.amount(gauge: effectiveGauge),
            whiteBalance: PlateWhiteBalance.adaptation(sceneKelvin: sceneIlluminantKelvin,
                                                       lockedKelvin: stock.colorTemperature),
            halationStrength: stock.halationStrength,
            halationRadiusFraction: stock.halationRadiusFraction,
            halationTint: stock.halationTint)
    }

    /// The same configuration magnified for the detail view. The grain and the halation are
    /// scaled with the crop, so the magnified card shows the real relative size of both.
    func withZoom(_ zoom: Float) -> PreviewConfiguration {
        PreviewConfiguration(footprint: footprint, amplitude: amplitude, whiteBalance: whiteBalance,
                             halationStrength: halationStrength,
                             halationRadiusFraction: halationRadiusFraction,
                             halationTint: halationTint, referenceLongEdge: referenceLongEdge,
                             zoom: zoom)
    }

    var isGrainVisible: Bool { footprint > 0 && amplitude > 0 }

    var isHalationVisible: Bool { halationStrength > 0 && halationRadiusFraction > 0 }

    var key: String {
        let m = whiteBalance
        return String(format: "%.3f|%.5f|%.5f|%.5f|%.0f|%.2f", footprint, amplitude,
                      halationStrength, halationRadiusFraction, referenceLongEdge, zoom)
            + String(format: "|%.5f,%.5f,%.5f", m.columns.0.x, m.columns.1.x, m.columns.2.x)
            + String(format: "|%.5f,%.5f,%.5f", m.columns.0.y, m.columns.1.y, m.columns.2.y)
            + String(format: "|%.5f,%.5f,%.5f", m.columns.0.z, m.columns.1.z, m.columns.2.z)
            + String(format: "|%.5f,%.5f,%.5f", halationTint.x, halationTint.y, halationTint.z)
    }

    static func == (lhs: PreviewConfiguration, rhs: PreviewConfiguration) -> Bool {
        lhs.footprint == rhs.footprint && lhs.amplitude == rhs.amplitude
            && lhs.halationStrength == rhs.halationStrength
            && lhs.halationRadiusFraction == rhs.halationRadiusFraction
            && lhs.halationTint == rhs.halationTint
            && lhs.referenceLongEdge == rhs.referenceLongEdge
            && lhs.zoom == rhs.zoom
            && lhs.whiteBalance.columns.0 == rhs.whiteBalance.columns.0
            && lhs.whiteBalance.columns.1 == rhs.whiteBalance.columns.1
            && lhs.whiteBalance.columns.2 == rhs.whiteBalance.columns.2
    }
}

/// The white balance the camera would leave on a scene, as a full colour transform.
///
/// `CameraSession.setWhiteBalance` locks the sensor to the selected stock's
/// `colorTemperature` with tint 0, so a scene lit at a different temperature records with its
/// neutral axis displaced by the illuminant ratio `I(scene) / I(locked)`. That ratio is a
/// chromatic adaptation, so it is applied as a full Bradford transform — never as a
/// per-channel gain. The transform is conjugated into **Apple Wide Gamut**, the primaries the
/// plates' linear values are in (Apple Log 2 white paper, the same primaries OCIO 2.6 uses for
/// `APPLE_LOG-APPLEWG_to_ACES2065-1`); deriving gains in linear sRGB and applying them to
/// Apple Wide Gamut values would mix two different bases.
enum PlateWhiteBalance {
    private static let bradford = simd_float3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])
    /// Apple Wide Gamut primaries and D65 white, from the Apple Log 2 white paper.
    private static let appleWideGamutToXYZ = primariesMatrix(red: SIMD2(0.725, 0.301),
                                                             green: SIMD2(0.221, 0.814),
                                                             blue: SIMD2(0.068, -0.076),
                                                             white: SIMD2(0.3127, 0.3290))
    private static let xyzToAppleWideGamut = appleWideGamutToXYZ.inverse
    /// Apple Wide Gamut luminance coefficients: the Y row of `appleWideGamutToXYZ`.
    private static let appleWideGamutLuma = SIMD3<Float>(appleWideGamutToXYZ[0][1],
                                                         appleWideGamutToXYZ[1][1],
                                                         appleWideGamutToXYZ[2][1])

    /// Full chromatic adaptation that carries the locked white onto the scene's white, in the
    /// plate's Apple Wide Gamut basis, normalised so the plate's neutral keeps its luminance
    /// (the lock changes colour, not exposure). Identity when the two agree.
    static func adaptation(sceneKelvin: Float, lockedKelvin: Float) -> simd_float3x3 {
        guard sceneKelvin > 0, lockedKelvin > 0 else { return matrix_identity_float3x3 }
        let cone = bradford * xyz(sceneKelvin) / (bradford * xyz(lockedKelvin))
        let inXYZ = bradford.inverse * simd_float3x3(diagonal: cone) * bradford
        var transform = xyzToAppleWideGamut * inXYZ * appleWideGamutToXYZ
        let neutral = transform * SIMD3<Float>(repeating: 1)
        let luminance = simd_dot(appleWideGamutLuma, neutral)
        guard luminance.isFinite, luminance > 0 else { return matrix_identity_float3x3 }
        transform = simd_float3x3(columns: (transform.columns.0 / luminance,
                                            transform.columns.1 / luminance,
                                            transform.columns.2 / luminance))
        let isFinite = transform.columns.0.x.isFinite && transform.columns.0.y.isFinite
            && transform.columns.0.z.isFinite && transform.columns.1.x.isFinite
            && transform.columns.1.y.isFinite && transform.columns.1.z.isFinite
            && transform.columns.2.x.isFinite && transform.columns.2.y.isFinite
            && transform.columns.2.z.isFinite
        return isFinite ? transform : matrix_identity_float3x3
    }

    /// CIE 1931 xy on the Planckian locus, Y = 1.
    private static func xyz(_ kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 1667), 25000)
        let x: Float = t <= 4000
            ? -0.2661239e9 / pow(t, 3) - 0.2343589e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390
        let y: Float
        if t <= 2222 {
            y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2) + 3.75112997 * x - 0.37001483
        }
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    /// RGB→XYZ for the given primaries, scaled so `white` maps to Y = 1.
    private static func primariesMatrix(red: SIMD2<Float>, green: SIMD2<Float>,
                                        blue: SIMD2<Float>, white: SIMD2<Float>) -> simd_float3x3 {
        func toXYZ(_ chromaticity: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(chromaticity.x / chromaticity.y, 1,
                  (1 - chromaticity.x - chromaticity.y) / chromaticity.y)
        }
        let primaries = simd_float3x3(toXYZ(red), toXYZ(green), toXYZ(blue))
        return primaries * simd_float3x3(diagonal: primaries.inverse * toXYZ(white))
    }
}

private struct PlatePage: View {
    let url: URL?
    let title: String
    let stockName: String
    let lutName: String
    let configuration: PreviewConfiguration
    /// Whether the card is showing its magnified crop.
    let isDetail: Bool
    let onToggleDetail: () -> Void

    /// The magnified crop's factor. Large enough that a shipping grain footprint resolves into
    /// several card pixels and a hairline halo becomes a visible fringe, so the two physically
    /// tiny effects can be seen at their real relative size instead of only measured.
    static let detailZoom: Float = 3

    private var effectiveConfiguration: PreviewConfiguration {
        configuration.withZoom(isDetail ? Self.detailZoom : 1)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            plate
            detailButton
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var plate: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let url {
                PlateSurface(plate: url, lutName: lutName, configuration: effectiveConfiguration)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo",
                                       description: Text("No plate for this scene."))
            }
        }
        .overlay(alignment: .bottomLeading) { caption }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(stockName), illustrative colour preview")
    }

    /// Optional and clearly labelled: the default card is the full photo, and this only ever
    /// magnifies the image the card already shows. It is kept as a sibling of the combined
    /// plate element so it stays a separate, tappable control for VoiceOver.
    private var detailButton: some View {
        Button(action: onToggleDetail) {
            Label(isDetail ? "Full photo" : "Detail",
                  systemImage: isDetail ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(12)
        .accessibilityLabel(isDetail ? "Show the full photo"
                                     : "Show a magnified detail of the grain and halation")
        .accessibilityAddTraits(isDetail ? [.isSelected] : [])
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            Text(stockName).font(.headline).foregroundStyle(.white)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }
}

#if os(iOS)
/// Metal surface for one plate. A plain layer-backed view rather than `MTKView`: the
/// preview is static, so it renders on demand instead of running a display link, which
/// also avoids `MTKViewDelegate`'s non-isolated callbacks under Swift 6.
private struct PlateSurface: UIViewRepresentable {
    let plate: URL
    let lutName: String
    let configuration: PreviewConfiguration

    func makeUIView(context: Context) -> PlateMetalView { PlateMetalView() }

    func updateUIView(_ view: PlateMetalView, context: Context) {
        view.show(plate: plate, lutName: lutName, configuration: configuration)
    }
}

final class PlateMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var renderer: PlateLUTRenderer?
    private var shown: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Loads the plate and cube only when the pair changes, then renders once.
    func show(plate: URL, lutName: String, configuration: PreviewConfiguration) {
        let key = "\(plate.path)|\(lutName)|\(configuration.key)"
        guard key != shown else { return }
        do {
            if renderer == nil { renderer = try PlateLUTRenderer(layer: metalLayer) }
            try renderer?.load(plate: plate, lutName: lutName, configuration: configuration)
            shown = key
        } catch {
            renderer = nil
            shown = nil
        }
        render()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        render()
    }

    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderer?.render()
    }
}
#else
/// macOS has no capture UI; the test target compiles this file for its contracts only.
private struct PlateSurface: View {
    let plate: URL
    let lutName: String
    let configuration: PreviewConfiguration

    var body: some View {
        if let image = PlateImage.load(plate) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "photo")
        }
    }
}
#endif

enum PlateImage {
    /// Decodes a plate at full resolution for upload.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0,
                                              [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// CPU mirror of the shader's `PlatePrepareUniforms`.
struct PlatePrepareUniformsCPU {
    var whiteBalance: simd_float3x3
}

/// CPU mirror of the shader's `PlatePreviewUniforms`. Field order and types must match
/// `Resources/Shaders/camera-preview.metal`; `PlatePreviewEffectsTests` pins the stride and
/// the last field's offset so a field added on only one side fails loudly.
struct PlatePreviewUniformsCPU {
    var uvScale: SIMD2<Float>
    var drawableSize: SIMD2<Float>
    var footprint: Float
    var amplitude: Float
    var offset: Float
    var referenceLongEdge: Float
    var zoom: Float

    static let identity = PlatePreviewUniformsCPU(uvScale: SIMD2(repeating: 1),
                                                  drawableSize: SIMD2(repeating: 1),
                                                  footprint: 0, amplitude: 0, offset: 0,
                                                  referenceLongEdge: PreviewConfiguration.defaultReferenceLongEdge,
                                                  zoom: 1)
}

/// The preview's render-on-demand chain, with no layer or view dependency so tests can drive
/// it headless: white-balance preparation, the production halation stage, the stock LUT, then
/// grain sized in the reference frame's pixels.
///
/// The plate ships as Apple Log 2 code values. The camera locks white balance in hardware
/// before the renderer sees a frame, so the preview reproduces that order: the lock is applied
/// in linear light and re-encoded to Apple Log 2 first, then the SAME `SpatialEffectsStage`
/// halation kernels the offline render uses run on that frame with the stock's own
/// strength/radius/tint, and only then does the LUT grade it. Grain is added last, in the
/// graded image, sampled in the reference frame's pixel space.
final class PlatePreviewPipeline: @unchecked Sendable {
    enum PipelineError: Error { case unavailable }

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private let queue: any MTLCommandQueue
    private let preparePipeline: any MTLComputePipelineState
    private let spatialStage: SpatialEffectsStage
    private var fragmentPipelines: [UInt: any MTLRenderPipelineState] = [:]

    private(set) var plateSize = SIMD2<Float>(1, 1)
    private(set) var configuration = PreviewConfiguration(footprint: 0, amplitude: 0,
                                                          whiteBalance: matrix_identity_float3x3,
                                                          halationStrength: 0,
                                                          halationRadiusFraction: 0,
                                                          halationTint: SIMD3(repeating: 0))
    private var preparedTexture: (any MTLTexture)?
    private var halatedTexture: (any MTLTexture)?
    private var lutTexture: (any MTLTexture)?
    private var grainVolume: (any MTLTexture)?

    init(device: any MTLDevice, library: any MTLLibrary, queue: any MTLCommandQueue) throws {
        guard let function = library.makeFunction(name: "plate_prepare") else {
            throw PipelineError.unavailable
        }
        self.preparePipeline = try device.makeComputePipelineState(function: function)
        self.spatialStage = try SpatialEffectsStage(device: device, library: library)
        self.device = device
        self.library = library
        self.queue = queue
    }

    /// Run the plate through white-balance preparation and the production halation stage once
    /// and retain the result, so each subsequent `render` is a single full-target pass.
    func load(plateTexture: any MTLTexture,
              plateSize: SIMD2<Float>,
              lutTexture: any MTLTexture,
              grainVolume: (any MTLTexture)?,
              configuration: PreviewConfiguration) throws {
        let width = Int(plateSize.x)
        let height = Int(plateSize.y)
        guard width > 0, height > 0 else { throw PipelineError.unavailable }
        guard let prepared = Self.makeScratch(device: device, width: width, height: height) else {
            throw PipelineError.unavailable
        }

        // 1. White balance, in linear light, re-encoded to Apple Log 2.
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.unavailable
        }
        var prepare = PlatePrepareUniformsCPU(whiteBalance: configuration.whiteBalance)
        encoder.setComputePipelineState(preparePipeline)
        encoder.setTexture(plateTexture, index: 0)
        encoder.setTexture(prepared, index: 1)
        encoder.setBytes(&prepare, length: MemoryLayout<PlatePrepareUniformsCPU>.stride, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw PipelineError.unavailable }

        // 2. The production halation stage, on the locked frame, with the stock's own
        //    parameters. Zero strength returns the prepared frame unchanged.
        guard let halated = spatialStage.applyHalation(
            source: prepared,
            commandQueue: queue,
            strength: configuration.halationStrength,
            radiusFraction: configuration.halationRadiusFraction,
            layerScale: configuration.halationTint,
            width: width,
            height: height
        ) else { throw PipelineError.unavailable }

        self.plateSize = plateSize
        self.configuration = configuration
        self.lutTexture = lutTexture
        self.grainVolume = grainVolume
        self.preparedTexture = prepared
        self.halatedTexture = halated
    }

    /// One full-target pass over the prepared frame: LUT, then gauge grain scaled to the
    /// reference frame. `presentOn` presents the drawable when the target came from a layer.
    @discardableResult
    func render(into target: any MTLTexture, drawableSize: CGSize,
                presentOn drawable: (any CAMetalDrawable)? = nil) -> Bool {
        guard let halated = halatedTexture, let lut = lutTexture,
              let pipeline = fragmentPipeline(for: target.pixelFormat),
              let command = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = PlatePreviewUniformsCPU(
            uvScale: Self.uvScale(plate: plateSize, drawable: drawableSize),
            drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            footprint: configuration.footprint,
            amplitude: configuration.isGrainVisible ? configuration.amplitude : 0,
            offset: Self.grainOffset,
            referenceLongEdge: configuration.referenceLongEdge,
            zoom: configuration.zoom)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PlatePreviewUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(halated, index: 0)
        encoder.setFragmentTexture(lut, index: 1)
        encoder.setFragmentTexture(grainVolume, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        if let drawable { command.present(drawable) }
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed
    }

    private func fragmentPipeline(for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let cached = fragmentPipelines[format.rawValue] { return cached }
        guard let vertex = library.makeFunction(name: "platePreviewVertex"),
              let fragment = library.makeFunction(name: "platePreviewFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        fragmentPipelines[format.rawValue] = state
        return state
    }

    // MARK: - Resources

    /// The shipped 128^3 grain volume the renderer samples, so the selector's grain is the
    /// same noise field rather than a second, invented texture.
    static func makeGrainVolume(device: any MTLDevice, bundle: Bundle = .main) -> (any MTLTexture)? {
        let path = bundle.path(forResource: "grain3d", ofType: "raw")
            ?? bundle.path(forResource: "grain3d", ofType: "raw", inDirectory: "Grain")
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return makeGrainVolume(data: data, device: device)
    }

    static func makeGrainVolume(data: Data, device: any MTLDevice) -> (any MTLTexture)? {
        let size = 128
        guard data.count >= size * size * size * MemoryLayout<Float>.size else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: size * MemoryLayout<Float>.size,
                            bytesPerImage: size * size * MemoryLayout<Float>.size)
        }
        return texture
    }

    /// Upload a plate to the Apple Log 2 code texture the prepare kernel reads. The plate is
    /// BGRA8 in memory but RGBA-ordered in the shader, matching the format it is stored as.
    static func makePlateTexture(_ image: CGImage, device: any MTLDevice) throws -> any MTLTexture {
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineError.unavailable
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw PipelineError.unavailable
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// Same direct RGB / red-fastest RGBA32Float upload as the capture preview.
    static func makeLUTTexture(_ cube: PlateCube, device: any MTLDevice) throws -> any MTLTexture {
        let size = cube.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineError.unavailable
        }
        cube.rgba.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                            bytesPerImage: size * size * 4 * MemoryLayout<Float>.size)
        }
        return texture
    }

    /// Aspect-fill: scale the sampled region so the plate's shape fills the card without
    /// being stretched (a shorter region crops instead).
    static func uvScale(plate: SIMD2<Float>, drawable: CGSize) -> SIMD2<Float> {
        let viewWidth = Float(drawable.width), viewHeight = Float(drawable.height)
        guard plate.x > 0, plate.y > 0, viewWidth > 0, viewHeight > 0 else {
            return SIMD2(repeating: 1)
        }
        let plateAspect = plate.x / plate.y
        let viewAspect = viewWidth / viewHeight
        return viewAspect > plateAspect
            ? SIMD2(plateAspect / viewAspect, 1)   // card wider than the plate: crop sides
            : SIMD2(1, viewAspect / plateAspect)   // card taller: crop top and bottom
    }

    /// Fixed phase: the preview is a still, so a per-frame index would only shimmer.
    static let grainOffset: Float = 0.37

    /// RGBA16Float scratch for the prepared (white-balanced) frame. GPU-only: nothing reads
    /// it back, so it stays `.private`.
    private static func makeScratch(device: any MTLDevice, width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                 width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}

/// Renders a plate through the preview chain into a layer drawable. One retained plate,
/// cube, grain volume and prepared frame; the preview is static, so each draw is a single
/// full-target pass.
final class PlateLUTRenderer: @unchecked Sendable {
    enum RenderError: Error { case unavailable }

    private let device: any MTLDevice
    private let layer: CAMetalLayer
    private let pipeline: PlatePreviewPipeline
    private var loaded: String?

    init(layer: CAMetalLayer) throws {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            throw RenderError.unavailable
        }
        self.device = device
        self.layer = layer
        self.pipeline = try PlatePreviewPipeline(device: device, library: library, queue: queue)
        layer.device = device
    }

    /// Uploads the pair and runs the preparation chain only when something changed.
    func load(plate: URL, lutName: String, configuration: PreviewConfiguration) throws {
        let key = "\(plate.path)|\(lutName)|\(configuration.key)"
        guard key != loaded else { return }
        let cube = try PlateCube.parse(Self.lutText(named: lutName))
        guard let image = PlateImage.load(plate) else { throw RenderError.unavailable }
        let plateTexture = try PlatePreviewPipeline.makePlateTexture(image, device: device)
        let lutTexture = try PlatePreviewPipeline.makeLUTTexture(cube, device: device)
        let grain = configuration.isGrainVisible
            ? PlatePreviewPipeline.makeGrainVolume(device: device) : nil
        try pipeline.load(plateTexture: plateTexture,
                          plateSize: SIMD2(Float(image.width), Float(image.height)),
                          lutTexture: lutTexture,
                          grainVolume: grain,
                          configuration: configuration)
        loaded = key
    }

    func render() {
        guard let drawable = layer.nextDrawable() else { return }
        pipeline.render(into: drawable.texture, drawableSize: layer.drawableSize, presentOn: drawable)
    }

    private static func lutText(named name: String) throws -> String {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: nil),
            bundle.url(forResource: name, withExtension: nil, subdirectory: "LUTs"),
            bundle.url(forResource: name, withExtension: nil, subdirectory: "Preview"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { throw RenderError.unavailable }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Minimal `.cube` reader for the preview cube.
///
/// Deliberately local to the selector: the FilmStockLibrary target also builds the macOS
/// CLI, which does not compile the capture module. Row order is preserved (red-fastest) so
/// the 3D upload matches the shader's `(code * (size - 1) + .5) / size` lookup.
struct PlateCube: Sendable {
    let size: Int
    let rgba: [Float]

    enum CubeError: Error { case invalid }

    static func parse(_ text: String) throws -> PlateCube {
        var size = 0
        var values: [Float] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let parsed = Int(parts[1]), parsed >= 2 else { throw CubeError.invalid }
                size = parsed
                continue
            }
            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_") { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            guard parts.count == 3 else { continue }
            values.append(contentsOf: [parts[0], parts[1], parts[2], 1])
        }
        guard size >= 2, values.count == size * size * size * 4 else { throw CubeError.invalid }
        return PlateCube(size: size, rgba: values)
    }
}
