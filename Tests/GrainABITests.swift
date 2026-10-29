import Foundation
import Testing
import Metal

/// Verifies the Swift `GrainUniforms` struct matches the Metal `GrainUniforms`
/// layout in `Resources/Shaders/grain.metal`
/// (uint/float/float/float/float/float, 24 bytes).
///
/// The field offset, stride, and actual GPU read-back checks here are what the
/// grain ABI defect was about: the Swift `frameIndex` was a `UInt` (8 bytes),
/// shifting `iso` and `grainSize` by 4 bytes on the Metal side. AD-9 widened the
/// struct to five floats for the print-gauge amplitude multiplier (m00581).
struct GrainABITests {
    @Test func layoutMatchesMetalABI() {
        #expect(MemoryLayout<GrainUniforms>.size == 24)
        #expect(MemoryLayout<GrainUniforms>.stride == 24)
        #expect(MemoryLayout<GrainUniforms>.alignment == 4)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.frameIndex) == 0)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.iso) == 4)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.grainSize) == 8)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.edgeBoostMultiplier) == 12)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.gaugeAmplitude) == 16)
        #expect(MemoryLayout<GrainUniforms>.offset(of: \.chromaAmount) == 20)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func gpuReceivesEdgeBoostMultiplierIntact() throws {
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
            float edgeBoostMultiplier;
            float gaugeAmplitude;
            float chromaAmount;
        };

        kernel void echo_grain_uniforms(
            constant GrainUniforms& u [[buffer(0)]],
            device uint* out [[buffer(1)]]
        ) {
            out[0] = u.frameIndex;
            out[1] = as_type<uint>(u.iso);
            out[2] = as_type<uint>(u.grainSize);
            out[3] = as_type<uint>(u.edgeBoostMultiplier);
            out[4] = as_type<uint>(u.gaugeAmplitude);
            out[5] = as_type<uint>(u.chromaAmount);
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "echo_grain_uniforms"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())

        let expectedISO = Float(123.456)
        let expectedGrainSize = Float(7.89)
        let expectedEdgeBoost = Float(2.75)
        let expectedGaugeAmplitude = Float(0.15)
        let expectedChromaAmount = Float(0.02)
        var uniforms = GrainUniforms(
            frameIndex: 0xDEAD_BEEF,
            iso: expectedISO,
            grainSize: expectedGrainSize,
            edgeBoostMultiplier: expectedEdgeBoost,
            gaugeAmplitude: expectedGaugeAmplitude,
            chromaAmount: expectedChromaAmount
        )
        let outBuffer = try #require(device.makeBuffer(length: MemoryLayout<UInt32>.size * 6, options: .storageModeShared))

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
        #expect(Float(bitPattern: out[3]) == expectedEdgeBoost)
        #expect(Float(bitPattern: out[4]) == expectedGaugeAmplitude)
        #expect(Float(bitPattern: out[5]) == expectedChromaAmount)
    }
}
