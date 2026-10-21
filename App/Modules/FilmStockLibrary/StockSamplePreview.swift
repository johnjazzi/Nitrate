import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import SwiftUI

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
    @State private var sceneID = ""
    private static let catalog = Result { try StockSampleCatalog.load() }

    var body: some View {
        switch Self.catalog {
        case .success(let catalog):
            VStack(spacing: 10) {
                pages(catalog)
                    .frame(height: 310)
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
                          lutName: stock?.lutName ?? "AppleLog2ToRec709.cube")
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
private struct PlatePage: View {
    let url: URL?
    let title: String
    let stockName: String
    let lutName: String

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let url {
                PlateSurface(plate: url, lutName: lutName)
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

    func makeUIView(context: Context) -> PlateMetalView { PlateMetalView() }

    func updateUIView(_ view: PlateMetalView, context: Context) {
        view.show(plate: plate, lutName: lutName)
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
    func show(plate: URL, lutName: String) {
        let key = "\(plate.path)|\(lutName)"
        guard key != shown else { return }
        do {
            if renderer == nil { renderer = try PlateLUTRenderer(layer: metalLayer) }
            try renderer?.load(plate: plate, lutName: lutName)
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
    func load(plate: URL, lutName: String) throws {
        let key = "\(plate.path)|\(lutName)"
        guard key != loaded else { return }
        let cube = try PlateCube.parse(Self.lutText(named: lutName))
        guard let image = PlateImage.load(plate) else { throw RenderError.unavailable }
        let plateTexture = try Self.makePlateTexture(image, device: device)
        let lutTexture = try Self.makeLUTTexture(cube, device: device)
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
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(plateTexture, index: 0)
        encoder.setFragmentTexture(lutTexture, index: 1)
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
