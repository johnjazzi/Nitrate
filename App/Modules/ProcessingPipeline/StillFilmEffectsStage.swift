import Foundation
import Metal

/// Photo-only orchestration of the established spatial effects and grain kernel.
/// Input and intermediate textures remain RGBA16Float; callers place this stage
/// around their photo LUT pass: halation before LUT, glow and grain after LUT.
/// The caller owns queue serialization and keeps the source textures alive.
final class StillFilmEffectsStage {
    private let device: MTLDevice
    private let grainPipeline: MTLComputePipelineState
    private let spatial: SpatialEffectsStage
    private let grainVolume: MTLTexture

    /// `grainVolume` must be the app's shipped 128³ `grain3d.raw` uploaded as
    /// r32Float, and `library` must be the app's actual default Metal library.
    /// Missing/wrong resources fail construction; no synthetic texture fallback.
    init(device: MTLDevice, library: MTLLibrary, grainVolume: MTLTexture) throws {
        guard grainVolume.textureType == .type3D,
              grainVolume.pixelFormat == .r32Float,
              grainVolume.width == 128, grainVolume.height == 128, grainVolume.depth == 128 else {
            throw RenderError.invalidGrainData
        }
        guard let function = library.makeFunction(name: "pass2_grain") else {
            throw RenderError.missingFunction("pass2_grain")
        }
        self.device = device
        self.grainPipeline = try device.makeComputePipelineState(function: function)
        self.spatial = try SpatialEffectsStage(device: device, library: library)
        self.grainVolume = grainVolume
    }

    /// Shared physical halation entry point. Source is Apple Log 2 RGBA16Float.
    func applyHalation(source: MTLTexture, commandQueue: MTLCommandQueue,
                       config: FilmStockConfig) -> MTLTexture? {
        guard source.pixelFormat == .rgba16Float else { return nil }
        return spatial.applyHalation(source: source, commandQueue: commandQueue,
                                     strength: config.halationStrength,
                                     radiusFraction: config.halationRadiusFraction,
                                     layerScale: config.halationTint,
                                     width: source.width, height: source.height)
    }

    /// Shared glow stage, invoked on the float gamma-2.4 LUT output.
    func applyGlow(graded: MTLTexture, commandQueue: MTLCommandQueue,
                   strength: Float) -> MTLTexture? {
        guard graded.pixelFormat == .rgba16Float else { return nil }
        return spatial.applyGlow(graded: graded, commandQueue: commandQueue,
                                 strength: strength, width: graded.width, height: graded.height)
    }

    /// Apply the exact video grain kernel/uniform ABI to a full-float still.
    /// `seed` selects a stable volume plane/offset; retries with the same seed
    /// and inputs are deterministic. Output remains RGBA16Float for later
    /// gamma-2.4 → sRGB conversion and JPEG encoding by the photo renderer.
    /// An explicit gain supports controlled still A/B without changing video or
    /// the shipping default. Zero is NOT grain-off: kernel dither remains.
    func applyGrain(graded: MTLTexture, commandQueue: MTLCommandQueue,
                    config: FilmStockConfig, gauge: PrintGauge, seed: UInt32,
                    stillPresenceGain: Float? = nil) -> MTLTexture? {
        let gain = stillPresenceGain ?? GrainModel.stillPresenceGain
        guard gain.isFinite, gain >= 0, graded.pixelFormat == .rgba16Float,
              let output = makeOutput(width: graded.width, height: graded.height),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        var uniforms = GrainUniforms(frameIndex: seed, iso: config.defaultISO,
                                     grainSize: GrainModel.effectiveSize(stockGrainSize: config.grainSize,
                                                                         gauge: gauge),
                                     edgeBoostMultiplier: config.effectiveRecipe.edgeBoostMultiplier,
                                     gaugeAmplitude: gauge.amplitudeMultiplier * gain,
                                     chromaAmount: GrainModel.stillChromaAmount)
        encoder.setComputePipelineState(grainPipeline)
        encoder.setTexture(graded, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(grainVolume, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: (graded.width + 15) / 16,
                                              height: (graded.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? output : nil
    }

    private func makeOutput(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                   width: width, height: height,
                                                                   mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
