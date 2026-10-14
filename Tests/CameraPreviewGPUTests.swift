import Foundation
import Metal
import Testing

/// Exercises the shipping shader on real Metal textures, not a camera/display calibration.
struct CameraPreviewGPUTests {
    private final class BundleToken {}
    private struct Uniforms {
        var imageScale = SIMD2<Float>(repeating: 1)
        var quarterTurns: UInt32 = 0
        var mirrored: UInt32 = 0
        var fullRange: UInt32 = 0
    }

    @Test(arguments: [Float(0.25), 0.5, 0.75])
    func packedLogCodesRenderThroughNeutralLUT(log: Float) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: BundleToken.self))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(library.makeFunction(name: "cameraPreviewVertex"))
        descriptor.fragmentFunction = try #require(library.makeFunction(name: "cameraPreviewFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        let luma = try makeTexture(device: device, format: .r16Unorm, usage: .shaderRead)
        let chroma = try makeTexture(device: device, format: .rg16Unorm, usage: .shaderRead)
        let output = try makeTexture(device: device, format: .bgra8Unorm, usage: .renderTarget)
        var y = UInt16((64 + 876 * log).rounded()) << 6
        withUnsafeBytes(of: &y) {
            luma.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: $0.baseAddress!, bytesPerRow: 2)
        }
        let cbcr: [UInt16] = [512 << 6, 512 << 6]
        cbcr.withUnsafeBytes {
            chroma.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        let (lut, expected) = try loadLUT(device: device, log: log)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = try #require(device.makeCommandQueue())
        let command = try #require(commands.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = Uniforms()
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.setFragmentTexture(lut, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        #expect(command.status == .completed)
        #expect(command.error == nil)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: 4,
                            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        for channel in pixel.prefix(3) {
            #expect(abs(Float(channel) / 255 - expected) < 0.005)
        }
        #expect(pixel[3] == 255)
        // A bypassed LUT would give .25/.5/.75, not these monitored values.
        #expect(abs(Float(pixel[0]) / 255 - log) > 0.02)
    }

    private func makeTexture(device: any MTLDevice, format: MTLPixelFormat,
                             usage: MTLTextureUsage) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func loadLUT(device: any MTLDevice, log: Float) throws -> (any MTLTexture, Float) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "App/Resources/Preview/AppleLog2ToRec709.cube"), encoding: .utf8)
        var values: [Float] = []
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            let rgb = words.compactMap { Float($0) }
            if words.count == 3, rgb.count == 3 { values.append(contentsOf: rgb + [1]) }
        }
        try #require(values.count == 33 * 33 * 33 * 4)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = 33
        descriptor.height = 33
        descriptor.depth = 33
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, 33, 33, 33), mipmapLevel: 0, slice: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 33 * 16, bytesPerImage: 33 * 33 * 16)
        }
        let axis = Int((log * 32).rounded())
        return (texture, values[(axis + axis * 33 + axis * 33 * 33) * 4])
    }
}
