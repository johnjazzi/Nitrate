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
/// Plates are illustrative — the author's own photographs pushed through the inverse of the
/// official neutral transform, not camera-recorded Apple Log 2 frames.
struct StockSamplePreview: View {
    let stock: FilmStockConfig?
    /// Print gauge, so the preview shows the grain that gauge produces.
    var gauge: PrintGauge?
    @State private var sceneID = ""
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
                                                              sceneIlluminantKelvin: scene.sceneIlluminantKelvin))
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
/// footprint the renderer would use, and the white-balance gain the camera would apply.
struct PreviewConfiguration: Equatable {
    let footprint: Float
    let amplitude: Float
    let whiteBalanceGain: SIMD3<Float>

    init(stock: FilmStockConfig?, gauge: PrintGauge?, sceneIlluminantKelvin: Float) {
        guard let stock else {
            self.footprint = 0
            self.amplitude = 0
            self.whiteBalanceGain = SIMD3(repeating: 1)
            return
        }
        self.footprint = GrainModel.effectiveSize(stockGrainSize: stock.grainSize,
                                                  gauge: gauge ?? stock.effectivePrintGauge)
        // Presence, not the render's exact amplitude: the selector shows which gauge is
        // coarser, not a calibrated grain loudness.
        self.amplitude = PreviewConfiguration.previewAmplitude
        self.whiteBalanceGain = PlateWhiteBalance.gain(sceneKelvin: sceneIlluminantKelvin,
                                                       lockedKelvin: stock.colorTemperature)
    }

    static let previewAmplitude: Float = 0.055

    var isGrainVisible: Bool { footprint > 0 && amplitude > 0 }
    var key: String { String(format: "%.3f|%.4f|%.4f|%.4f|%.4f",
                             footprint, whiteBalanceGain.x, whiteBalanceGain.y, whiteBalanceGain.z,
                             amplitude) }
}

/// The white balance the camera would leave on a scene, as a per-channel linear gain.
///
/// `CameraSession.setWhiteBalance` locks the sensor to the selected stock's
/// `colorTemperature` with tint 0, so a scene lit at a different temperature records with its
/// neutral axis displaced by `I(scene) / I(locked)`. Mirrors the generator's model: Planckian
/// locus (Kim et al. 1997) -> XYZ -> Bradford adaptation -> linear sRGB -> luminance-normalised.
enum PlateWhiteBalance {
    private static let bradford = simd_float3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])
    private static let xyzToSRGB = simd_float3x3(rows: [
        SIMD3(3.2406, -1.5372, -0.4986),
        SIMD3(-0.9689, 1.8758, 0.0415),
        SIMD3(0.0557, -0.2040, 1.0570),
    ])
    private static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    static func gain(sceneKelvin: Float, lockedKelvin: Float) -> SIMD3<Float> {
        guard sceneKelvin > 0, lockedKelvin > 0 else { return SIMD3(repeating: 1) }
        let adaptation = bradford.inverse * diagonal(bradford * xyz(sceneKelvin)
                                                     / (bradford * xyz(lockedKelvin))) * bradford
        let toSRGB = xyzToSRGB * adaptation * xyzToSRGB.inverse
        var white = toSRGB * SIMD3(repeating: 1)
        white = simd_max(white, SIMD3(repeating: 1e-6))
        let luminance = simd_dot(white, luma)
        guard luminance.isFinite, luminance > 0 else { return SIMD3(repeating: 1) }
        let gain = white / luminance
        return gain.x.isFinite && gain.y.isFinite && gain.z.isFinite ? gain : SIMD3(repeating: 1)
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

    private static func diagonal(_ v: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(rows: [SIMD3(v.x, 0, 0), SIMD3(0, v.y, 0), SIMD3(0, 0, v.z)])
    }
}

private struct PlatePage: View {
    let url: URL?
    let title: String
    let stockName: String
    let lutName: String
    let configuration: PreviewConfiguration

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let url {
                PlateSurface(plate: url, lutName: lutName, configuration: configuration)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo",
                                       description: Text("No plate for this scene."))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .bottomLeading) { caption }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(stockName), illustrative colour preview")
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

/// Renders a plate through a cube. One retained plate texture and one cube; the preview is
/// static, so each draw is a single full-target pass.
final class PlateLUTRenderer: @unchecked Sendable {
    enum RenderError: Error { case unavailable }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let layer: CAMetalLayer
    private var plateTexture: (any MTLTexture)?
    private var lutTexture: (any MTLTexture)?
    private var grainVolume: (any MTLTexture)?
    private var plateSize = SIMD2<Float>(1, 1)
    private var configuration = PreviewConfiguration(stock: nil, gauge: nil, sceneIlluminantKelvin: 5600)
    private var loaded: String?

    init(layer: CAMetalLayer) throws {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "platePreviewVertex"),
              let fragment = library.makeFunction(name: "platePreviewFragment") else {
            throw RenderError.unavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.layer = layer
        layer.device = device
    }

    /// Uploads the pair only when it changes; the caller renders afterwards.
    func load(plate: URL, lutName: String, configuration: PreviewConfiguration) throws {
        let key = "\(plate.path)|\(lutName)|\(configuration.key)"
        guard key != loaded else { return }
        let cube = try PlateCube.parse(Self.lutText(named: lutName))
        guard let image = PlateImage.load(plate) else { throw RenderError.unavailable }
        let plateTexture = try Self.makePlateTexture(image, device: device)
        let lutTexture = try Self.makeLUTTexture(cube, device: device)
        if configuration.isGrainVisible, grainVolume == nil {
            grainVolume = Self.makeGrainVolume(device: device)
        }
        self.plateSize = SIMD2(Float(image.width), Float(image.height))
        self.configuration = configuration
        self.plateTexture = plateTexture
        self.lutTexture = lutTexture
        loaded = key
    }

    func render() {
        guard let plateTexture, let lutTexture,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = PlatePreviewUniformsCPU(
            whiteBalanceGain: configuration.whiteBalanceGain,
            footprint: configuration.footprint,
            amplitude: configuration.amplitude,
            offset: Self.grainOffset,
            uvScale: Self.uvScale(plate: plateSize, drawable: layer.drawableSize))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PlatePreviewUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(plateTexture, index: 0)
        encoder.setFragmentTexture(lutTexture, index: 1)
        encoder.setFragmentTexture(grainVolume, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    // MARK: - Resources

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

    private static func makePlateTexture(_ image: CGImage, device: any MTLDevice) throws -> any MTLTexture {
        let width = image.width, height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height,
                                                                 mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw RenderError.unavailable
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// The shipped 128^3 grain volume the renderer samples, so the selector's grain is the
    /// same noise field rather than a second, invented texture.
    private static func makeGrainVolume(device: any MTLDevice) -> (any MTLTexture)? {
        let bundle = Bundle.main
        let path = bundle.path(forResource: "grain3d", ofType: "raw")
            ?? bundle.path(forResource: "grain3d", ofType: "raw", inDirectory: "Grain")
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
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
    private static let grainOffset: Float = 0.37

    /// Same direct RGB / red-fastest RGBA32Float upload as the capture preview.
    private static func makeLUTTexture(_ cube: PlateCube, device: any MTLDevice) throws -> any MTLTexture {
        let size = cube.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
        cube.rgba.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                            bytesPerImage: size * size * 4 * MemoryLayout<Float>.size)
        }
        return texture
    }
}

/// Minimal `.cube` reader for the preview cube.
///
/// Deliberately local to the selector: the FilmStockLibrary target also builds the macOS
/// CLI, which does not compile the capture module. Row order is preserved (red-fastest) so
/// the 3D upload matches the shader's `(code * (size - 1) + .5) / size` lookup.
/// CPU mirror of the shader's `PlatePreviewUniforms`.
struct PlatePreviewUniformsCPU {
    var whiteBalanceGain: SIMD3<Float>
    var footprint: Float
    var amplitude: Float
    var offset: Float
    var uvScale: SIMD2<Float>

    static let identity = PlatePreviewUniformsCPU(whiteBalanceGain: SIMD3(repeating: 1),
                                                  footprint: 0, amplitude: 0, offset: 0,
                                                  uvScale: SIMD2(repeating: 1))
}

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
