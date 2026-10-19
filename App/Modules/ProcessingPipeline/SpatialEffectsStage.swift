import Foundation
import Metal
import MetalPerformanceShaders
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

    /// Blur radius as a fraction of the half-resolution width for the wide
    /// glow bloom. Proportional rather than a fixed texel count so the look is
    /// resolution-independent instead of shrinking on larger frames. Halation
    /// radius is NOT here: it is per-stock geometry (emulsion thickness / stock
    /// speed), supplied by `FilmStockConfig.halationRadiusFraction`.
    private static let glowRadiusFraction: Float = 0.05

    /// Ring/tail balance for halation, in `0...1`: 1 subtracts the source
    /// highlight fully so the added light is a pure ring in the tail, 0 leaves
    /// the raw blurred mask so the effect reads as a soft filled glow. Kept
    /// global (like the thresholds and `shadowFloor`) because the user asked for
    /// halation geometry — radius and tint — to be per-stock, not the shape
    /// knob. Lower it toward 0 if the ring reads too hollow on device.
    private static let ringTailBalance: Float = 1.0

    /// Colour cast for the wide glow bloom. Red light scatters furthest inside
    /// the emulsion; glow is a subtler amber. Full-scale colours: how *much*
    /// light is added belongs to the stock's strength dial, not to a dim tint.
    /// (The old per-pixel glow carried its dimming in a 0.1-magnitude tint,
    /// which made glow ten times weaker than halation once the two went through
    /// the same compositing path.) Halation's tint is per-stock and lives in
    /// `FilmStockConfig.halationTint`.
    private static let glowTint = SIMD3<Float>(1.0, 0.55, 0.25)

    /// Luma below which added light is faded out, so the effect never lifts the
    /// black point (which the old constant glow term did).
    private static let shadowFloor: Float = 0.08

    private let device: MTLDevice
    private let maskPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    /// Match the old nine-tap kernel's second moment without its detached lobes.
    /// sqrt(2 * sum(weight[i] * offset[i]^2)) = sqrt(7.6260355034).
    /// Scaling sparse offsets separated sharp copies of the mask; MPS instead
    /// continuously convolves it at this standard deviation in both axes.
    private static let blurSigmaPerRadius: Float = 2.7615277481

    init(device: MTLDevice, library: MTLLibrary) throws {
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.maskPipeline = try pipeline("spatial_mask")
        self.compositePipeline = try pipeline("spatial_composite")
    }

    /// Apply halation and glow to an already-graded texture, returning a new
    /// texture that carries the result. `graded` is never mutated.
    func apply(
        graded: MTLTexture,
        commandQueue: MTLCommandQueue,
        halationStrength: Float,
        glowStrength: Float,
        halationRadiusFraction: Float,
        halationTint: SIMD3<Float>,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let halfWidth = max(1, width / 2)
        let halfHeight = max(1, height / 2)

        guard let mask = makeTexture(width: halfWidth, height: halfHeight),
              let halationDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let glowDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let composited = makeTexture(width: width, height: height, storageMode: .shared),
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
        // Halation radius is per-stock (emulsion thickness / speed); glow stays
        // a fixed fraction of width.
        let halationRadius = max(2, Float(halfWidth) * halationRadiusFraction)
        let glowRadius = max(4, Float(halfWidth) * Self.glowRadiusFraction)

        // 2. Narrow blur → halation diffusion.
        blurContinuously(
            source: mask,
            destination: halationDiffusion,
            radius: halationRadius,
            commandBuffer: commandBuffer
        )

        // 3. Wide blur → glow diffusion.
        blurContinuously(
            source: mask,
            destination: glowDiffusion,
            radius: glowRadius,
            commandBuffer: commandBuffer
        )

        // 4. Composite halation, then glow, each with its own cast and strength.
        //    Halation is a ring (ring/tail balance 1); glow passes 0 so it stays
        //    a plain bloom rather than acquiring a hole.
        composite(
            source: graded,
            diffusion: halationDiffusion,
            into: composited,
            strength: halationStrength,
            tint: halationTint,
            ringTailBalance: Self.ringTailBalance,
            commandBuffer: commandBuffer,
            groups: fullGroups
        )
        composite(
            source: composited,
            diffusion: glowDiffusion,
            into: composited,
            strength: glowStrength,
            tint: Self.glowTint,
            ringTailBalance: 0,
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

    /// A continuous, efficient Gaussian approximation, including at 4K radii.
    /// Clamp boundaries preserve uniform highlights instead of darkening edges.
    private func blurContinuously(
        source: MTLTexture,
        destination: MTLTexture,
        radius: Float,
        commandBuffer: MTLCommandBuffer
    ) {
        let blur = MPSImageGaussianBlur(device: device, sigma: radius * Self.blurSigmaPerRadius)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
    }

    /// Add one blurred diffusion layer onto `source`, writing to `into`.
    /// `ringTailBalance` is 1 for the halation ring, 0 for the glow bloom.
    private func composite(
        source: MTLTexture,
        diffusion: MTLTexture,
        into: MTLTexture,
        strength: Float,
        tint: SIMD3<Float>,
        ringTailBalance: Float,
        commandBuffer: MTLCommandBuffer,
        groups: MTLSize
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var strength = strength
        var shadowFloor = Self.shadowFloor
        var tint = tint
        var ringTailBalance = ringTailBalance
        var thresholdLow = Self.thresholdLow
        var thresholdHigh = Self.thresholdHigh

        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(diffusion, index: 1)
        encoder.setTexture(into, index: 2)
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shadowFloor, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&tint, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        encoder.setBytes(&ringTailBalance, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&thresholdLow, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&thresholdHigh, length: MemoryLayout<Float>.size, index: 5)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.groupSize)
        encoder.endEncoding()
    }

    /// RGBA16Float scratch texture, readable and samplable by the kernels.
    /// GPU-only scratch (mask, diffusion) is `.private`: leaving storageMode
    /// unset defaults to `.shared` on iOS, and CPU-coherent memory costs real
    /// bandwidth for passes that never touch the CPU. The returned composite
    /// stays `.shared` because callers (and the spatial tests) read it back.
    /// Measured on an A20 Pro GPU at 3840x2160: all-shared 3.30 ms vs
    /// all-private 1.31 ms for identical passes, so the split matters.
    private func makeTexture(width: Int, height: Int,
                             storageMode: MTLStorageMode = .private) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = storageMode
        return device.makeTexture(descriptor: desc)
    }
}
