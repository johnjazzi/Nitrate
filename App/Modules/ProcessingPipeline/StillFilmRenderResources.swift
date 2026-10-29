import CoreImage
import Metal
import Foundation

/// One render owns its GPU resources; no shared mutable Video renderer state.
final class StillFilmRenderResources {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let effects: StillFilmEffectsStage
    let config: FilmStockConfig
    let gauge: PrintGauge
    let seed: UInt32
    private let space: CGColorSpace
    private let lutPipeline: MTLComputePipelineState
    private let bundle: Bundle

    init(stockID: String, gauge: PrintGauge, seed: UInt32, bundle: Bundle = .main) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: bundle),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let catalog = bundle.url(forResource: "stocks", withExtension: "json"),
              let grain = bundle.url(forResource: "grain3d", withExtension: "raw", subdirectory: "Grain")
                ?? bundle.url(forResource: "grain3d", withExtension: "raw") else {
            throw DevelopmentPhotoRenderer.RenderError.decode("Still GPU resources are unavailable")
        }
        struct Catalog: Decodable { let stocks: [FilmStockConfig] }
        let stocks = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalog)).stocks
        guard let config = stocks.first(where: { $0.stockId == stockID }) else {
            throw DevelopmentPhotoRenderer.RenderError.unsupportedStock(stockID)
        }
        try config.validate()
        let bytes = try Data(contentsOf: grain)
        let n = 128
        guard bytes.count == n * n * n * MemoryLayout<Float>.size else { throw RenderError.invalidGrainData }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = n; descriptor.height = n; descriptor.depth = n
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let volume = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }
        bytes.withUnsafeBytes { pointer in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                           withBytes: pointer.baseAddress!, bytesPerRow: n * 4, bytesPerImage: n * n * 4)
        }
        self.device = device; self.queue = queue; self.space = space
        self.context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .cacheIntermediates: false])
        self.effects = try StillFilmEffectsStage(device: device, library: library, grainVolume: volume)
        guard let lutFunction = library.makeFunction(name: "pass1_lut_halation_glow") else {
            throw RenderError.missingFunction("pass1_lut_halation_glow")
        }
        self.lutPipeline = try device.makeComputePipelineState(function: lutFunction)
        self.bundle = bundle
        self.config = config; self.gauge = gauge; self.seed = seed
    }

    private func texture(_ image: CIImage) throws -> MTLTexture {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0,
              extent.width * extent.height <= Double(PhotoCapturePolicy.maximumPixelCount) else {
            throw DevelopmentPhotoRenderer.RenderError.decode("Invalid still extent")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: Int(extent.width), height: Int(extent.height), mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw RenderError.textureCreationFailed
        }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        context.render(normalized, to: texture, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: texture.width, height: texture.height), colorSpace: space)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw RenderError.stageFailed("photo-ci", "Still texture rendering failed") }
        return texture
    }

    private func image(_ texture: MTLTexture) throws -> CIImage {
        // These channels carry encoded intermediate values, not display RGB.
        // Tag with the working space so Core Image preserves those channel values.
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: space]) else {
            throw RenderError.textureCreationFailed
        }
        return image
    }

    /// Exact Video LUT sampling, texel-center interpolation, and contrast ABI.
    func grade(_ source: CIImage, resourcesURL: URL? = nil) throws -> CIImage {
        let name = (config.lutName as NSString).deletingPathExtension
        guard let url = resourcesURL?.appendingPathComponent(config.lutName)
            ?? bundle.url(forResource: name, withExtension: "cube", subdirectory: "LUTs")
            ?? bundle.url(forResource: name, withExtension: "cube") else {
            throw RenderError.missingResource(config.lutName)
        }
        let (size, values) = try PhotoCubeLUT.parse(String(contentsOf: url, encoding: .utf8))
        let cubeDescriptor = MTLTextureDescriptor()
        cubeDescriptor.textureType = .type3D
        cubeDescriptor.pixelFormat = .rgba32Float
        cubeDescriptor.width = size; cubeDescriptor.height = size; cubeDescriptor.depth = size
        cubeDescriptor.storageMode = .shared
        cubeDescriptor.usage = [.shaderRead]
        let input = try texture(source)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: input.width, height: input.height, mipmapped: false)
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let lut = device.makeTexture(descriptor: cubeDescriptor),
              let output = device.makeTexture(descriptor: outputDescriptor),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw RenderError.textureCreationFailed
        }
        values.withUnsafeBytes { pointer in
            lut.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                withBytes: pointer.baseAddress!, bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        }
        var zero: Float = 0
        var contrast = config.outputContrast
        encoder.setComputePipelineState(lutPipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1); encoder.setTexture(lut, index: 2)
        encoder.setBytes(&zero, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&zero, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&contrast, length: MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + 15) / 16, height: (input.height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw RenderError.stageFailed("photo-lut", "Still LUT failed") }
        return try image(output)
    }

    func halation(_ source: CIImage) throws -> CIImage {
        let input = try texture(source)
        guard let result = effects.applyHalation(source: input, commandQueue: queue, config: config) else {
            throw RenderError.stageFailed("photo-halation", "Still halation failed")
        }
        return try image(result)
    }

    func glowAndGrain(_ graded: CIImage) throws -> CIImage {
        let input = try texture(graded)
        guard let glowed = effects.applyGlow(graded: input, commandQueue: queue, strength: config.glowStrength),
              let grained = effects.applyGrain(graded: glowed, commandQueue: queue,
                                              config: config, gauge: gauge, seed: seed) else {
            throw RenderError.stageFailed("photo-grain", "Still glow or grain failed")
        }
        return try image(grained)
    }
}
