import CoreImage
import CoreVideo
import Foundation
import Metal

/// Actor-confined color resources. No spatial-effect or grain resources exist here.
final class DevelopColorPreviewResources {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let bundle: Bundle
    private let lutPipeline: MTLComputePipelineState
    private let hlgPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache
    private var luts: [String: MTLTexture] = [:]
    private var curveKey: String?
    private var cachedCurve: [UInt16] = []

    init(bundle: Bundle) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.textureCreationFailed
        }
        let library = try device.makeDefaultLibrary(bundle: bundle)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw RenderError.missingFunction(name) }
            return try device.makeComputePipelineState(function: function)
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw RenderError.textureCreationFailed
        }
        self.device = device
        self.queue = queue
        self.bundle = bundle
        self.textureCache = cache
        self.lutPipeline = try pipeline("pass1_lut_halation_glow")
        self.hlgPipeline = try pipeline("hlg_prepare")
        self.context = CIContext(mtlDevice: device, options: [.workingColorSpace: space, .cacheIntermediates: false])
    }

    private func texture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }
        return texture
    }

    func materialize(_ image: CIImage) throws -> MTLTexture {
        let output = try texture(width: Int(image.extent.width), height: Int(image.extent.height))
        guard let command = queue.makeCommandBuffer() else { throw RenderError.textureCreationFailed }
        context.render(image, to: output, commandBuffer: command, bounds: image.extent, colorSpace: space)
        try finish(command)
        return output
    }

    /// Exact production HLG adapter; do not ask Core Image to reinterpret YUV.
    func prepare(_ buffer: CVPixelBuffer) throws -> MTLTexture {
        guard let profile = RenderInputColorProvenance.profile(of: buffer) else {
            throw DevelopFramePreviewRenderer.PreviewError.unsupportedVideo
        }
        var references: [CVMetalTexture] = []
        func plane(_ index: Int, _ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
            var reference: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                width, height, index, &reference) == kCVReturnSuccess,
                let reference, let texture = CVMetalTextureGetTexture(reference) else {
                throw RenderError.textureCreationFailed
            }
            references.append(reference)
            return texture
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let output = try texture(width: width, height: height)
        guard let command = queue.makeCommandBuffer() else { throw RenderError.textureCreationFailed }
        if profile == .appleLog2 {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf,
                  let blit = command.makeBlitCommandEncoder() else { throw RenderError.textureCreationFailed }
            let input = try plane(0, .rgba16Float, width, height)
            blit.copy(from: input, to: output)
            blit.endEncoding()
        } else {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                  CVPixelBufferGetPlaneCount(buffer) == 2,
                  let encoder = command.makeComputeCommandEncoder() else { throw RenderError.textureCreationFailed }
            let y = try plane(0, .r16Unorm, width, height)
            let chroma = try plane(1, .rg16Unorm, CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1))
            encoder.setComputePipelineState(hlgPipeline)
            encoder.setTexture(y, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(output, index: 2)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        try finish(command)
        withExtendedLifetime(references) {}
        return output
    }

    func grade(_ input: MTLTexture, stock: FilmStockConfig, pushPull: PushPullExposure,
               ceiling: Float? = nil) throws -> CIImage {
        let rowBytes = input.width * 8
        var words = [UInt16](repeating: 0, count: input.width * input.height * 4)
        input.getBytes(&words, bytesPerRow: rowBytes,
                       from: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0)
        if !pushPull.isNeutral {
            let step = max(1, Int((Double(input.width * input.height) / 65_536).squareRoot().rounded(.up)))
            var peaks: [Float] = []
            for y in stride(from: 0, to: input.height, by: step) {
                for x in stride(from: 0, to: input.width, by: step) {
                    let index = (y * input.width + x) * 4
                    peaks.append((0..<3).map { Float(Float16(bitPattern: words[index + $0])) }.max()!)
                }
            }
            let hold = ceiling ?? PushPullTransfer.measuredHighlightCeiling(peakCodes: peaks)
                ?? SpatialEffectsStage.halationCeiling(sceneLiftStops: 0)
            // Exhaustive half-float lookup of the existing production curve, not
            // an interpolated look. Avoid millions of per-pixel pow/log calls.
            let key = "\(pushPull.stops.stops):\(hold.bitPattern)"
            if curveKey != key {
                cachedCurve = (0...Int(UInt16.max)).map { bits in
                    Float16(PushPullTransfer.gained(code: Float(Float16(bitPattern: UInt16(bits))),
                        stops: pushPull.stops, ceiling: hold)).bitPattern
                }
                curveKey = key
            }
            let curve = cachedCurve
            for index in words.indices where index % 4 != 3 {
                if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
                words[index] = curve[Int(words[index])]
            }
        }
        let exposed = try texture(width: input.width, height: input.height)
        exposed.replace(region: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0,
                        withBytes: words, bytesPerRow: rowBytes)
        let lut: MTLTexture
        if let cached = luts[stock.lutName] {
            lut = cached
        } else {
            let name = (stock.lutName as NSString).deletingPathExtension
            guard let url = bundle.url(forResource: name, withExtension: "cube", subdirectory: "LUTs")
                ?? bundle.url(forResource: name, withExtension: "cube") else { throw RenderError.missingResource(stock.lutName) }
            let (size, values) = try PhotoCubeLUT.parse(String(contentsOf: url, encoding: .utf8))
            guard let loaded = FilterableLUTTexture.make(device: device, size: size, rgba: values) else {
                throw RenderError.textureCreationFailed
            }
            luts[stock.lutName] = loaded
            lut = loaded
        }
        let output = try texture(width: input.width, height: input.height)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw RenderError.textureCreationFailed
        }
        var zero: Float = 0
        var contrast = stock.outputContrast
        encoder.setComputePipelineState(lutPipeline)
        encoder.setTexture(exposed, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&zero, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&zero, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&contrast, length: MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + 15) / 16, height: (input.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        try finish(command)
        guard let image = CIImage(mtlTexture: output, options: [.colorSpace: space]) else {
            throw RenderError.textureCreationFailed
        }
        return image
    }

    private func finish(_ command: MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        try Task.checkCancellation()
        guard command.status == .completed else { throw RenderError.stageFailed("preview-color", "Color preview failed") }
    }
}
