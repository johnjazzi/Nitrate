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
/// blurred mask back with a colour cast.
///
/// The mask is built and blurred at HALF resolution. Halation and glow are
/// low-frequency by nature, so half-res blurring is visually equivalent while
/// cutting scratch-texture work and bandwidth by roughly 4x at 4K.
///
/// HALATION is now physical, GLOW is not. Halation reads the ungraded Apple Log 2
/// frame, decodes it to linear scene light, and takes the excess above each
/// emulsion layer's knee; the three layers are then diffused at their own radii.
/// That is what produces the red -> warm red -> white ramp and the growing source
/// of real halation, rather than a tint applied to one shared luma mask. Glow is
/// an optical-filter bloom with no such physical model, so it keeps the graded
/// luma mask and the stock tint it always had — its look is deliberately
/// unchanged by this work.
///
/// Owns its own pipeline states so the renderer does not have to expose them.
final class SpatialEffectsStage {
    /// Highlight window for the GLOW mask only, carried over from the original
    /// per-pixel implementation. Halation no longer thresholds a luma value: it
    /// uses per-layer knees in linear light (below).
    private static let thresholdLow: Float = 0.7
    private static let thresholdHigh: Float = 0.95

    /// Blur radius as a fraction of the half-resolution width for the wide
    /// glow bloom. Proportional rather than a fixed texel count so the look is
    /// resolution-independent instead of shrinking on larger frames. Halation
    /// radius is NOT here: it is per-stock geometry (emulsion thickness / stock
    /// speed), supplied by `FilmStockConfig.halationRadiusFraction`.
    private static let glowRadiusFraction: Float = 0.05

    /// Ring/tail balance for the glow bloom; see `spatial_composite`.
    private static let ringTailBalance: Float = 1.0

    /// Colour cast for the wide glow bloom. Halation no longer has a tint — its
    /// colour is emergent from the per-layer physics.
    private static let glowTint = SIMD3<Float>(1.0, 0.55, 0.25)

    /// Luma below which added light is faded out, so the effect never lifts the
    /// black point.
    private static let shadowFloor: Float = 0.08

    // MARK: - Physical halation parameters
    //
    // These are the per-layer constants of the model. The per-stock knobs remain
    // `halationRadiusFraction` (the base diffusion radius), `halationStrength`
    // and `halationTint` (now the per-layer contribution weight); the channel
    // ratios below are global, and are the values to tune first when the halo
    // reads wrong on device.

    /// Per-layer diffusion radius, as a multiple of the stock's base radius.
    /// Red scatters furthest through the emulsion, blue least — this is the
    /// single most visible property of real halation and the first
    /// implementation had no way to express it (one blur, one radius).
    private static let redRadiusMultiplier: Float = 1.8
    private static let greenRadiusMultiplier: Float = 1.0
    private static let blueRadiusMultiplier: Float = 0.5

    /// Per-layer knees, in multiples of diffuse white (decoded linear 1.0 = 100%
    /// scene reflection). Red is re-exposed by the least scattered light and blue
    /// by the most, so red responds first. The ordering is what makes a faint
    /// halo read red and a bright one read white: as intensity climbs the source
    /// clears more knees, which is also why a very bright source appears to grow.
    private static let redKnee: Float = 1.0
    private static let greenKnee: Float = 2.0
    private static let blueKnee: Float = 4.0

    /// Superwhite excess that reaches full contribution. Apple Log 2 tops out
    /// near 12x diffuse white, so normalizing by 8 leaves headroom instead of
    /// letting an 11x specular swamp the graded image.
    private static let referenceSuperwhite: Float = 8.0

    private let device: MTLDevice
    private let maskPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let halationMaskPipeline: MTLComputePipelineState
    private let halationCompositePipeline: MTLComputePipelineState

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
        self.halationMaskPipeline = try pipeline("spatial_halation_mask")
        self.halationCompositePipeline = try pipeline("spatial_halation_composite")
    }

    /// Apply halation and glow to an already-graded texture, returning a new
    /// texture that carries the result. Neither `graded` nor `input` is mutated.
    ///
    /// `input` is the UNGRADED Apple Log 2 frame. Halation needs it because the
    /// graded image has already been through the display transform, which maps
    /// both a 2x and a 100x specular to about 1.0 — the superwhite separation
    /// halation depends on only exists before the LUT.
    func apply(
        graded: MTLTexture,
        input: MTLTexture,
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

        guard let glowMask = makeTexture(width: halfWidth, height: halfHeight),
              let glowDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let halationMask = makeTexture(width: halfWidth, height: halfHeight),
              let redDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let greenDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let blueDiffusion = makeTexture(width: halfWidth, height: halfHeight),
              let composited = makeTexture(width: width, height: height, storageMode: .shared),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let halfGroups = threadgroups(width: halfWidth, height: halfHeight)
        let fullGroups = threadgroups(width: width, height: height)

        // 1. Glow highlight mask: graded luma, untinted, at half resolution.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var low = Self.thresholdLow
            var high = Self.thresholdHigh
            encoder.setComputePipelineState(maskPipeline)
            encoder.setTexture(graded, index: 0)
            encoder.setTexture(glowMask, index: 1)
            encoder.setBytes(&low, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&high, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(halfGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        // 2. Halation mask: per-layer superwhite excess, decoded from the
        //    ungraded frame. Separate from the glow mask because it needs the
        //    linear scene light the graded image no longer carries.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var red = Self.redKnee
            var green = Self.greenKnee
            var blue = Self.blueKnee
            encoder.setComputePipelineState(halationMaskPipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(halationMask, index: 1)
            encoder.setBytes(&red, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&green, length: MemoryLayout<Float>.size, index: 1)
            encoder.setBytes(&blue, length: MemoryLayout<Float>.size, index: 2)
            encoder.dispatchThreadgroups(halfGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        // Radii scale with the frame so the effect looks the same at any size.
        // Halation radius is per-stock (emulsion thickness / speed); glow stays
        // a fixed fraction of width.
        let baseRadius = max(2, Float(halfWidth) * halationRadiusFraction)
        let glowRadius = max(4, Float(halfWidth) * Self.glowRadiusFraction)

        // 3. One blur per emulsion layer: red widest, then green, then blue.
        //    MPSImageGaussianBlur convolves every channel at one sigma, so the
        //    per-layer radii need three passes over the shared mask.
        blurContinuously(
            source: halationMask,
            destination: redDiffusion,
            radius: max(2, baseRadius * Self.redRadiusMultiplier),
            commandBuffer: commandBuffer
        )
        blurContinuously(
            source: halationMask,
            destination: greenDiffusion,
            radius: max(2, baseRadius * Self.greenRadiusMultiplier),
            commandBuffer: commandBuffer
        )
        blurContinuously(
            source: halationMask,
            destination: blueDiffusion,
            radius: max(2, baseRadius * Self.blueRadiusMultiplier),
            commandBuffer: commandBuffer
        )

        // 4. Wide blur for the glow bloom, off the graded mask.
        blurContinuously(
            source: glowMask,
            destination: glowDiffusion,
            radius: glowRadius,
            commandBuffer: commandBuffer
        )

        // 5. Composite halation, then glow. Halation adds the per-layer light
        //    with the stock's layer weights; glow keeps its tint and ring shape.
        halationComposite(
            source: graded,
            redDiffusion: redDiffusion,
            greenDiffusion: greenDiffusion,
            blueDiffusion: blueDiffusion,
            into: composited,
            strength: halationStrength,
            layerScale: halationTint,
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

    /// Add the three diffused halation layers onto `source`, writing to `into`.
    ///
    /// The three diffusions are sampled separately and recombined by channel, so
    /// each layer keeps its own reach. Red contributes most because it is the
    /// layer most re-exposed by scattered light; where green and blue have also
    /// responded the sum tends toward white.
    private func halationComposite(
        source: MTLTexture,
        redDiffusion: MTLTexture,
        greenDiffusion: MTLTexture,
        blueDiffusion: MTLTexture,
        into: MTLTexture,
        strength: Float,
        layerScale: SIMD3<Float>,
        commandBuffer: MTLCommandBuffer,
        groups: MTLSize
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var strength = strength
        var shadowFloor = Self.shadowFloor
        var layerScale = layerScale
        var referenceSuperwhite = Self.referenceSuperwhite

        encoder.setComputePipelineState(halationCompositePipeline)
        // Three separate bindings, not one combined texture: each layer is
        // diffused at its own radius, so combining them into one rgb texture
        // first would need an extra full pass over all three.
        encoder.setTexture(source, index: 0)
        encoder.setTexture(redDiffusion, index: 1)
        encoder.setTexture(greenDiffusion, index: 2)
        encoder.setTexture(blueDiffusion, index: 3)
        encoder.setTexture(into, index: 4)
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shadowFloor, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        encoder.setBytes(&referenceSuperwhite, length: MemoryLayout<Float>.size, index: 3)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.groupSize)
        encoder.endEncoding()
    }

    /// Add one blurred diffusion layer onto `source`, writing to `into`.
    /// `ringTailBalance` is 1 for the glow ring, 0 for a plain bloom.
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
