import Foundation
import Metal
import Testing

struct FilterableLUTTextureTests {
    @Test func unsupportedFloat32FilteringRequiresFilterableHalfStorage() {
        #expect(FilterableLUTTexture.format(supports32BitFloatFiltering: false) == .rgba16Float)
        #expect(FilterableLUTTexture.format(supports32BitFloatFiltering: true) == .rgba32Float)
    }

    @Test func halfCubeInterpolatesOffGridAsymmetricGradientThroughProductionKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = 4
        var rgba: [Float] = []
        func grade(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
            SIMD3(0.61*r + 0.19*g + 0.07*b + 0.01,
                  0.11*r + 0.71*g + 0.03*b + 0.02,
                  0.23*r + 0.13*g + 0.51*b + 0.03)
        }
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = grade(Float(r)/3, Float(g)/3, Float(b)/3)
                    rgba += [v.x, v.y, v.z, 1]
                }
            }
        }
        let lut = try #require(FilterableLUTTexture.make(device: device, size: size, rgba: rgba, preferHalfPrecision: true))
        #expect(lut.pixelFormat == .rgba16Float)
        let width = 1024
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: width, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let pixels = (0..<width).map { i -> SIMD4<Float> in
            let t = Float(i) / Float(width - 1)
            return SIMD4(0.1 + 0.8*t, 0.2 + 0.5*t, 0.05 + 0.3*t, 1)
        }
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        final class BundleToken {}
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: BundleToken.self))
        let function = try #require(library.makeFunction(name: "pass1_lut_halation_glow"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        var zero: Float = 0
        var one: Float = 1
        encoder.setBytes(&zero, length: 4, index: 0)
        encoder.setBytes(&zero, length: 4, index: 1)
        encoder.setBytes(&one, length: 4, index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var readback = [SIMD4<Float>](repeating: .zero, count: width)
        readback.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                            from: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0)
        }
        var maxError: Float = 0
        var maxStep: Float = 0
        for i in 0..<width {
            let expected = grade(pixels[i].x, pixels[i].y, pixels[i].z)
            for c in 0..<3 {
                maxError = max(maxError, abs(readback[i][c] - expected[c]))
                if i > 0 { maxStep = max(maxStep, abs(readback[i][c] - readback[i - 1][c])) }
            }
        }
        #expect(maxError < 0.001, "Half storage must preserve RGB axes and interpolation, not produce nearest-neighbor bands")
        #expect(maxStep < 0.002)
        #expect(FilterableLUTTexture.make(device: device, size: 4, rgba: [1, 2, 3]) == nil)
    }
}
