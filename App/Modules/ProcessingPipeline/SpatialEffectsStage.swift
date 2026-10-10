import Foundation
import Metal
import simd

/// Spatial halation + glow (epic story 1.4).
///
/// The first implementation of halation and glow was purely per-pixel: it added a
/// warm term scaled by each pixel's own luma, so a highlight could never bleed
/// *neighbourhood* information into the pixels around it, and glow was a constant
/// frame-wide lift that raised the black point. This stage does it spatially
/// instead: build a highlight mask once, blur it separably, then composite the
/// blurred mask back with a colour cast. Bright areas now bleed warm light into
/// their surroundings the way light scattering inside film does.
///
/// The mask is built and blurred at HALF resolution. Halation and glow are
/// low-frequency by nature, so half-res blurring is visually equivalent while
/// cutting scratch-texture work and bandwidth by roughly 4x at 4K.
///
/// Owns its own pipeline states so the renderer does not have to expose them.
final class SpatialEffectsStage {
    /// Highlight window, carried over from the original per-pixel implementation.
    private static let thresholdLow: Float = 0.7
    private static let thresholdHigh: Float = 0.95

    /// Blur radii as a fraction of the half-resolution width: a tight halo plus
    /// a wide bloom. Proportional rather than fixed texel counts so the look is
    /// resolution-independent instead of shrinking on larger frames.
    private static let halationRadiusFraction: Float = 0.012
    private static let glowRadiusFraction: Float = 0.05

    /// Colour casts. Red light scatters furthest inside the emulsion, which is
    /// why halation skews red; glow is a subtler amber. Both are full-scale
    /// colours: how *much* light is added belongs to the stock's strength dial,
    /// not to a dim tint. (The old per-pixel glow carried its dimming in a
    /// 0.1-magnitude tint, which made glow ten times weaker than halation once
    /// the two went through the same compositing path.)
    private static let halationTint = SIMD3<Float>(1.0, 0.4, 0.2)
    private static let glowTint = SIMD3<Float>(1.0, 0.55, 0.25)

    /// Luma below which added light is faded out, so the effect never lifts the
    /// black point (which the old constant glow term did).
    private static let shadowFloor: Float = 0.08

    private let device: MTLDevice
    private let maskPipeline: MTLComputePipelineState
    private let blurHPipeline: MTLComputePipelineState
    private let blurVPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary) throws {
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.maskPipeline = try pipeline("spatial_mask")
        self.blurHPipeline = try pipeline("spatial_blur_h")
        self.blurVPipeline = try pipeline("spatial_blur_v")
        self.compositePipeline = try pipeline("spatial_composite")
    }

    /// Apply halation and glow to an already-graded texture, returning a new
    /// texture that carries the result. `graded` is never mutated.
    func apply(
        graded: MTLTexture,
        commandQueue: MTLCommandQueue,
        halationStrength: Float,
        glowStrength: Float,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let halfWidth = max(1, width / 2)
        let halfHeight = max(1, height / 2)

        guard let mask = makeTexture(width: halfWidth, height: halfHeight),
              let blurScratch = makeTexture(width: halfWidth, height: halfHeight),
              let halationDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let glowDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let composited = makeTexture(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let halfGroups = threadgroups(width: halfWidth, height: halfHeight)
        let fullGroups = threadgroups(width: width, height: height)

        // 1. Highlight mask, untinted, at half resolution. Untinted so a single
        //    blur pair can feed both effects, which use different colour casts.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var low = Self.thresholdLow
            var high = Self.thresholdHigh
            encoder.setComputePipelineState(maskPipeline)
            encoder.setTexture(graded, index: 0)
            encoder.setTexture(mask, index: 1)
            encoder.setBytes(&low, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&high, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(halfGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        // Radii scale with the frame so the effect looks the same at any size.
        let halationRadius = max(2, Float(halfWidth) * Self.halationRadiusFraction)
        let glowRadius = max(4, Float(halfWidth) * Self.glowRadiusFraction)

        // 2. Narrow blur → halation diffusion.
        blurSeparably(
            source: mask,
            destination: halationDiffusion,
            scratch: blurScratch,
            radius: halationRadius,
            commandBuffer: commandBuffer,
            groups: halfGroups
        )

        // 3. Wide blur → glow diffusion.
        blurSeparably(
            source: mask,
            destination: glowDiffusion,
            scratch: blurScratch,
            radius: glowRadius,
            commandBuffer: commandBuffer,
            groups: halfGroups
        )

        // 4. Composite halation, then glow, each with its own cast and strength.
        composite(
            source: graded,
            diffusion: halationDiffusion,
            into: composited,
            strength: halationStrength,
            tint: Self.halationTint,
            commandBuffer: commandBuffer,
            groups: fullGroups
        )
        composite(
            source: composited,
            diffusion: glowDiffusion,
            into: composited,
            strength: glowStrength,
            tint: Self.glowTint,
            commandBuffer: commandBuffer,
            groups: fullGroups
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? composited : nil
    }

    // MARK: - Kernel dispatch

    private static let groupSize = MTLSize(width: 16, height: 16, depth: 1)

    private func threadgroups(width: Int, height: Int) -> MTLSize {
        MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
    }

    /// One separable Gaussian blur: horizontal into `scratch`, then vertical out
    /// of it into `destination`.
    private func blurSeparably(
        source: MTLTexture,
        destination: MTLTexture,
        scratch: MTLTexture,
        radius: Float,
        commandBuffer: MTLCommandBuffer,
        groups: MTLSize
    ) {
        var radius = radius

        guard let horizontal = commandBuffer.makeComputeCommandEncoder() else { return }
        horizontal.setComputePipelineState(blurHPipeline)
        horizontal.setTexture(source, index: 0)
        horizontal.setTexture(scratch, index: 1)
        horizontal.setBytes(&radius, length: MemoryLayout<Float>.size, index: 0)
        horizontal.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.groupSize)
        horizontal.endEncoding()

        guard let vertical = commandBuffer.makeComputeCommandEncoder() else { return }
        vertical.setComputePipelineState(blurVPipeline)
        vertical.setTexture(scratch, index: 0)
        vertical.setTexture(destination, index: 1)
        vertical.setBytes(&radius, length: MemoryLayout<Float>.size, index: 0)
        vertical.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.groupSize)
        vertical.endEncoding()
    }

    /// Add one blurred diffusion layer onto `source`, writing to `into`.
    private func composite(
        source: MTLTexture,
        diffusion: MTLTexture,
        into: MTLTexture,
        strength: Float,
        tint: SIMD3<Float>,
        commandBuffer: MTLCommandBuffer,
        groups: MTLSize
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var strength = strength
        var shadowFloor = Self.shadowFloor
        var tint = tint

        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(diffusion, index: 1)
        encoder.setTexture(into, index: 2)
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shadowFloor, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.groupSize)
        encoder.endEncoding()
    }

    /// RGBA16Float scratch texture, readable and samplable by the kernels.
    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)
    }
}
