import Foundation
import Testing
import Metal

/// Verifies the Swift `GrainUniforms` struct matches the Metal `GrainUniforms`
/// layout in `Resources/Shaders/grain.metal` (uint/float/float/float, 16 bytes).
///
/// The field offset, stride, and actual GPU read-back checks here are what the
/// grain ABI defect was about: the Swift `frameIndex` was a `UInt` (8 bytes),
/// shifting `iso` and `grainSize` by 4 bytes on the Metal side.
struct GrainABITests {
    @Test func layoutMatchesMetalABI() {
        #expect(MemoryLayout<GrainUniforms>.size == 16)
        #expect(MemoryLayout<GrainUniforms>.stride == 16)
        #expect(MemoryLayout<GrainUniforms>.alignment == 4)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.frameIndex) == 0)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.iso) == 4)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.grainSize) == 8)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.padding) == 12)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func gpuReceivesISOAndGrainSizeIntact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

        // Same struct layout as Resources/Shaders/grain.metal, so this kernel
        // reads exactly what the production grain kernel reads.
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct GrainUniforms {
            uint  frameIndex;
            float iso;
            float grainSize;
            float padding;
        };

        kernel void echo_grain_uniforms(
            constant GrainUniforms& u [[buffer(0)]],
            device uint4* out [[buffer(1)]]
        ) {
            out[0] = uint4(u.frameIndex,
                           as_type<uint>(u.iso),
                           as_type<uint>(u.grainSize),
                           as_type<uint>(u.padding));
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "echo_grain_uniforms"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())

        let expectedISO = Float(123.456)
        let expectedGrainSize = Float(7.89)
        var uniforms = GrainUniforms(
            frameIndex: 0xDEAD_BEEF,
            iso: expectedISO,
            grainSize: expectedGrainSize,
            padding: 42.0
        )
        let outBuffer = try #require(device.makeBuffer(length: MemoryLayout<UInt32>.size * 4, options: .storageModeShared))

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let out = outBuffer.contents().assumingMemoryBound(to: UInt32.self)
        #expect(out[0] == 0xDEAD_BEEF)
        #expect(Float(bitPattern: out[1]) == expectedISO)
        #expect(Float(bitPattern: out[2]) == expectedGrainSize)
        #expect(Float(bitPattern: out[3]) == 42.0)
    }
}
