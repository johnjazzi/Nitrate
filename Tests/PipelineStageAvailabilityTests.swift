import Foundation
import Metal
import Testing

/// Regression cover for the failure mode where a render silently produced the
/// *original* footage: every GPU stage depends on its kernel resolving from
/// `default.metallib`, and the renderer reports failure by throwing. If the
/// app-level caller swallows that error and saves the source instead, the user
/// sees ungraded, ungrainy, metadata-less video with no diagnostic.
///
/// These tests pin the two halves of that contract:
///   1. every kernel the pipeline needs is actually present in the metallib
///      that ships inside the app bundle, and
///   2. the grain stage really adds noise at a given ISO (so "no grain" cannot
///      be a silent no-op).
@Suite("Pipeline stage availability")
struct PipelineStageAvailabilityTests {

    /// Kernels `PipelineRenderer` and `SpatialEffectsStage` request by name.
    private static let requiredKernels = [
        "pass1_lut_halation_glow",
        "pass2_grain",
        "spatial_mask",
        "spatial_blur_h",
        "spatial_blur_v",
        "spatial_composite"
    ]

    /// The project's own metallib, compiled by xcodebuild for the test host.
    private static func projectLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Tests run inside the xctest agent, so Bundle.main points at Xcode's
        // own directory. Start from the test bundle instead and walk up to the
        // products directory, where xcodebuild leaves default.metallib next to
        // the executable the app itself loads it from.
        var directory = Bundle(for: BundleToken.self).bundleURL
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("default.metallib")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try device.makeLibrary(URL: candidate)
            }
            directory = directory.deletingLastPathComponent()
        }

        // Packaged app: the library ships in the bundle.
        if let bundled = try? device.makeDefaultLibrary(bundle: .main) {
            return bundled
        }
        throw TestFailure("default.metallib not found near \(Bundle(for: BundleToken.self).bundleURL.path)")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Anchor for locating the test bundle.
    private final class BundleToken {}

    /// Every kernel the render pipeline needs must resolve. A missing kernel
    /// throws `RenderError.missingFunction`, which the render worker turns into
    /// a failed job — but the visible symptom is unprocessed video, so it is
    /// worth failing loudly here instead.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func everyPipelineKernelIsPresentInTheMetallib() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Self.projectLibrary(device: device)

        for name in Self.requiredKernels {
            #expect(
                library.makeFunction(name: name) != nil,
                "kernel '\(name)' is missing from the metallib; the render would fail and fall back to the source clip"
            )
        }
    }

    private static let side = 128

    /// Flat mid-grey RGBA16Float input, sampled by the grain kernel.
    private static func makeFlatInput(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false
        )
        desc.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: desc))
        let values = [Float16](repeating: 0.5, count: side * side * 4)
        values.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, side, side),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: side * 4 * MemoryLayout<Float16>.size
            )
        }
        return texture
    }

    /// A grain volume with real variance, so the kernel has something to sample
    /// and the test cannot pass vacuously.
    private static func makeGrainVolume(device: MTLDevice) throws -> MTLTexture {
        var values = [Float](repeating: 0, count: side * side * side)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in 0..<values.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float((seed >> 11) & 0xFFFFFF) / Float(0xFFFFFF)
            values[index] = 0.5 + (unit - 0.5) * 0.12
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .r32Float
        desc.width = side
        desc.height = side
        desc.depth = side
        desc.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: desc))
        values.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, side, side, side),
                mipmapLevel: 0,
                slice: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: side * MemoryLayout<Float>.size,
                bytesPerImage: side * side * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private static func makeOutput(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false
        )
        desc.usage = [.shaderWrite]
        return try #require(device.makeTexture(descriptor: desc))
    }

    /// Run the grain kernel once at `iso` and return the red-channel standard
    /// deviation of the result.
    private static func redStdDev(
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        iso: Float
    ) throws -> Double {
        let input = try makeFlatInput(device: device)
        let output = try makeOutput(device: device)
        let grainVolume = try makeGrainVolume(device: device)

        var uniforms = GrainUniforms(frameIndex: 0, iso: iso, grainSize: 1.3, edgeBoostMultiplier: 0)
        let buffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(grainVolume, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (side + 15) / 16, height: (side + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed, "grain kernel did not complete")

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { pointer in
            output.getBytes(
                pointer.baseAddress!,
                bytesPerRow: side * 4,
                from: MTLRegionMake2D(0, 0, side, side),
                mipmapLevel: 0
            )
        }

        let reds = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        let mean = reds.reduce(0, +) / Double(reds.count)
        let variance = reds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(reds.count)
        return variance.squareRoot()
    }

    /// The grain kernel must actually change the image, and more strongly at a
    /// higher ISO. This is the property that was silently lost when the CPU and
    /// Metal grain uniform layouts disagreed.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainKernelAddsNoiseThatScalesWithISO() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try Self.projectLibrary(device: device)
        let function = try #require(library.makeFunction(name: "pass2_grain"))
        let pipeline = try device.makeComputePipelineState(function: function)

        let lowISO = try Self.redStdDev(device: device, queue: queue, pipeline: pipeline, iso: 100)
        let highISO = try Self.redStdDev(device: device, queue: queue, pipeline: pipeline, iso: 2000)

        #expect(lowISO > 0.2, "grain must visibly perturb a flat frame (std \(lowISO))")
        #expect(highISO > lowISO * 2, "grain must scale with ISO (\(lowISO) -> \(highISO))")
    }
}
