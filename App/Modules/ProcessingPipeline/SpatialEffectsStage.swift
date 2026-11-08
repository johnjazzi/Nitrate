import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// Spatial halation + glow (epic story 1.4).
///
/// The stage owns two INDEPENDENT effects, applied at different points in the
/// render and for different reasons. Keeping them separate is the whole point:
///
///  * HALATION is physical and PRE-LUT. `applyHalation(source:...)` decodes the
///    ungraded Apple Log 2 frame to linear scene light, takes each emulsion
///    layer's excess above its knee, diffuses the three layers at their own
///    radii, adds the scattered energy back in LINEAR light, and re-encodes to
///    Apple Log 2. The renderer then runs the stock LUT and output contrast on
///    that re-encoded frame, so the scattered light is tone-mapped by the same
///    curve as the light that produced it — the halo rolls off with the
///    highlight instead of clipping into a detached fringe. The graded image is
///    never read and there is no background-dependent shadow gate: the light
///    that scatters is the light that is added.
///
///  * GLOW is an optical-filter bloom with no physical model.
///    `applyGlow(graded:...)` keeps the graded-luminance highlight mask and the
///    tinted additive composite it always had, applied POST-LUT. Its look is
///    deliberately unchanged by the halation work.
///
///  * DIFFUSION is the lens filter and is also PRE-LUT, in scene-linear light.
///    It softens the scene before the emulsion scatters it: the frame is blended
///    toward a multi-scale Gaussian blur (`DiffusionPlan`) and the result feeds
///    halation. It shares halation's decode and its single encode, so enabling
///    it costs the blur passes and nothing else.
///
/// Masks and diffusions are built and blurred at HALF resolution. Halation and
/// glow are low-frequency by nature, so half-res blurring is visually equivalent
/// while cutting scratch-texture work and bandwidth by roughly 4x at 4K.
///
/// Owns its own pipeline states so the renderer does not have to expose them.
final class SpatialEffectsStage {
    // MARK: - Glow parameters (unchanged look)

    /// Highlight window for the GLOW mask only, carried over from the original
    /// per-pixel implementation. Halation no longer thresholds a luma value: it
    /// uses per-layer knees in linear light (below).
    private static let thresholdLow: Float = 0.7
    private static let thresholdHigh: Float = 0.95

    /// Blur radius as a fraction of the half-resolution width for the wide
    /// glow bloom. Proportional rather than a fixed texel count so the look is
    /// resolution-independent instead of shrinking on larger frames. Halation
    /// radius is NOT here: it is per-stock geometry (emulsion thickness / stock
    /// speed), supplied by `halationRadiusFraction`.
    private static let glowRadiusFraction: Float = 0.05

    /// Colour cast for the wide glow bloom. Halation no longer has a tint — its
    /// colour is emergent from the per-layer physics.
    private static let glowTint = SIMD3<Float>(1.0, 0.55, 0.25)

    /// Luma below which added glow light is faded out, so the bloom never lifts
    /// the black point. Halation has no such gate: it adds the light it scatters.
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
    private static let redKnee: Float = 0.75
    private static let greenKnee: Float = 1.5
    private static let blueKnee: Float = 3.0

    /// Superwhite excess that reaches full contribution. Apple Log 2 tops out
    /// near 12x diffuse white. Lower knees and a 10x excess reference widen
    /// the ramp so it starts sooner and builds more gradually, instead of
    /// letting an 11x specular swamp the graded image.
    private static let referenceSuperwhite: Float = 10.0

    /// Apple Log 2's recorded range tops out near 12x diffuse white (code 1.0
    /// decodes to ~12.0), so a video frame is truly clipped there. See the
    /// superwhite note in `spatial.metal`.
    static let appleLog2ClipWhite: Float = 12.0

    /// The knees above, expressed in the light a caller actually hands in.
    ///
    /// The knees are authored for Apple Log 2, where decoded 1.0 is 100 % scene
    /// reflection. A still that the RAW decoder lifted by N stops is N stops
    /// brighter in every pixel, so measuring its excess against the un-lifted
    /// knees reports ordinary lit surfaces as superwhite: measured on a ProRAW
    /// carrying BaselineExposure +2.99 EV, an indoor wall sat at ~2x white, so
    /// it cleared the red AND green knees on every pixel and the whole frame
    /// bloomed orange. Scaling the knees by the same lift measures the same
    /// quantity the video path measures.
    ///
    /// `sceneLiftStops` is zero for every video frame and for any still whose
    /// decode was not lifted, in which case this is exactly `(0.75, 1.5, 3)`.
    static func halationKnees(sceneLiftStops: Float) -> SIMD3<Float> {
        SIMD3(redKnee, greenKnee, blueKnee) * liftScale(sceneLiftStops)
    }

    // MARK: - Where halation reaches full contribution

    /// Share of a STILL's measured highlight ceiling at which the halo is at full
    /// strength. Not used for video, which has no measurement to apply it to.
    ///
    /// This is a DENOMINATOR, not a knee: the per-layer knees decide WHICH light
    /// bleeds, this decides how much of the requested strength a given excess
    /// buys. Lower it and every pixel above a knee contributes more, which is the
    /// lever for "DSLR halation should read stronger". 1.0 would anchor exactly to
    /// the file's brightest 0.01%; 0.15625 stretches the previous 0.125 ramp by
    /// 25%, matching the gentler video reference.
    ///
    /// One number on purpose: halve it to double the effect.
    static let stillAnchorShare: Float = 0.15625

    /// Floor under that anchor, in multiples of white, so a frame with almost no
    /// light above white cannot drive the denominator toward zero and veil itself.
    ///
    /// It bites on ordinary DSLR frames (a NEF measures ~1.03x white), so it is
    /// the second knob: lower it to let `stillAnchorShare` act, raise it to hold
    /// the effect back. Tuned together with the share — changing one alone moves
    /// nothing on the files the two knobs were fitted to.
    static let stillAnchorFloorWhite: Float = 0.078125

    /// The superwhite value at which halation reaches FULL contribution.
    ///
    /// VIDEO passes no `headroom` and gets the authored constant: the knees and
    /// this reference were designed for Apple Log 2, which carries about 12x
    /// diffuse white, and 10x leaves room for an 11x specular without letting it
    /// swamp the graded frame. Every video frame is therefore unchanged by
    /// anything in this section.
    ///
    /// A STILL passes `headroom`, the file's own measured ceiling in the same
    /// lifted units as the frame (see `RAWPhotoDecoder.measureHeadroom`). A
    /// single-exposure raw CLIPS at its own white: across 35 DSLR raws the
    /// brightest 0.01% of pixels sat at 0.5-3.7x white, so against the authored 8x
    /// halation reached 7-48% of its range and the halo read faint. Anchoring to
    /// what the file actually carries puts a clipped specular - and a clipped sky,
    /// which is clipped all the same - at full contribution.
    ///
    /// Both ends scale with the decode lift, exactly as the knees do, so a lifted
    /// still is measured against the same scene it came from (`halationKnees`).
    /// The result never exceeds the authored value, however bright the file.
    static func halationReferenceSuperwhite(sceneLiftStops: Float, headroom: Float? = nil) -> Float {
        let lift = liftScale(sceneLiftStops)
        let authored = referenceSuperwhite * lift
        guard let headroom, headroom.isFinite else { return authored }
        let anchored = headroom * stillAnchorShare
        return min(authored, max(lift * stillAnchorFloorWhite, anchored))
    }

    private static func liftScale(_ sceneLiftStops: Float) -> Float {
        let lift = sceneLiftStops.isFinite ? max(-8, min(8, sceneLiftStops)) : 0
        return pow(2, lift)
    }

    /// The scene-light value at which a source is TRULY CLIPPED — the top of its
    /// recorded range, in the same lifted units as the frame.
    ///
    /// This is the ceiling the push/pull curve holds (`spatial_expose`): a
    /// highlight at or above it carries no scene detail to recover, so the gain
    /// fades to none there and the pixel stays white and keeps halating. What
    /// "truly clipped" means is a property of the SOURCE, so it is measured
    /// wherever it can be: a still clips at its `headroom`
    /// (see `halationReferenceSuperwhite`), a take at its `highlightCeiling`.
    /// Apple Log 2's ~12x white is only the fallback — it is the top of the
    /// RECORDING range, and holding there would let a pull crush a dimmer
    /// highlight that is nevertheless blown.
    static func halationCeiling(sceneLiftStops: Float,
                                headroom: Float? = nil,
                                highlightCeiling: Float? = nil) -> Float {
        if let measured = highlightCeiling ?? headroom, measured.isFinite, measured > 0 {
            return measured
        }
        return appleLog2ClipWhite * liftScale(sceneLiftStops)
    }

    private let device: MTLDevice
    private let glowMaskPipeline: MTLComputePipelineState
    private let glowCompositePipeline: MTLComputePipelineState
    private let halationMaskPipeline: MTLComputePipelineState
    private let halationApplyPipeline: MTLComputePipelineState
    private let scenePreparePipeline: MTLComputePipelineState
    private let diffusionDownsamplePipeline: MTLComputePipelineState
    private let diffusionBlurPipeline: MTLComputePipelineState

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
        self.glowMaskPipeline = try pipeline("spatial_mask")
        self.glowCompositePipeline = try pipeline("spatial_composite")
        self.halationMaskPipeline = try pipeline("spatial_halation_mask")
        self.halationApplyPipeline = try pipeline("spatial_halation_apply")
        self.scenePreparePipeline = try pipeline("spatial_scene_prepare")
        self.diffusionDownsamplePipeline = try pipeline("diffusion_downsample")
        self.diffusionBlurPipeline = try pipeline("diffusion_blur")
    }

    // MARK: - Halation (pre-LUT)

    /// Apply physical halation — and, when enabled, the lens diffusion node — to
    /// the UNGRADED Apple Log 2 frame, and return a new texture carrying the
    /// result, still Apple Log 2 encoded, ready to be graded by the stock LUT
    /// and output contrast. `source` is not mutated.
    ///
    /// `strength` is the stock's halation strength (0 disables halation only).
    /// Exposure still runs when halation and diffusion are disabled; byte-for-byte
    /// passthrough requires both effects disabled AND `exposureStops == 0`.
    /// `radiusFraction` is the base diffusion radius as a fraction of the
    /// half-resolution width; `layerScale` weights the three per-layer
    /// contributions. A radius of 0 means no spatial diffusion — the scattered
    /// energy is still added, but locally, over the source's own footprint.
    ///
    /// `diffusion` is the lens filter in front of the emulsion. Both effects are
    /// scene-linear and pre-LUT, so they share ONE decode and ONE encode: the
    /// prepare pass writes the halation mask and the linear scene together, the
    /// blur passes run over the linear scene, and the apply pass blends the
    /// diffusion and adds the halation energy before encoding once. Disabling
    /// diffusion bypasses its blend, not the requested exposure or halation.
    func applyHalation(
        source: MTLTexture,
        commandQueue: MTLCommandQueue,
        strength: Float,
        radiusFraction: Float,
        layerScale: SIMD3<Float>,
        diffusion: DiffusionSettings = .disabled,
        sceneLiftStops: Float = 0,
        /// Measured highlight ceiling of a still, in lifted units. Nil for video,
        /// which keeps the authored reference. See `halationReferenceSuperwhite`.
        halationHeadroom: Float? = nil,
        /// The take's own highlight ceiling, in the frame's scene units, measured
        /// from the source frames. A take's halation reference stays authored (see
        /// `halationReferenceSuperwhite`), but the push/pull hold must anchor to
        /// what THIS take carries: a hazy sky tops out near 3x white, and a hold
        /// anchored at Apple Log 2's 12x would let a pull drag it down into the
        /// stock's cast. Nil for a still, which measures its own `halationHeadroom`.
        highlightCeiling: Float? = nil,
        /// Render-time exposure in stops, applied to the scene BEFORE the emulsion
        /// stages: a video take is locked to its shutter, so the operator pulls a
        /// bright day down in the render, and halation has to be measured against
        /// the light the film actually receives. Stills pass 0 — their exposure is
        /// baked into the decode.
        exposureStops: Float = 0,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let plan = diffusion.plan(sourceWidth: width)
        // Only all three disabled means byte-for-byte identity, including Log noise.
        guard strength != 0 || plan != nil || exposureStops != 0 else { return source }

        let halfWidth = max(1, (width + 1) / 2)
        let halfHeight = max(1, (height + 1) / 2)
        // At zero diffusion, use a full-resolution mask so down/up-sampling
        // cannot spread a one-pixel source despite the blur being disabled.
        // Without halation the mask has nothing to carry and stays half-res, and
        // so does the diffusion node's scene: the prepare kernel writes both
        // textures at the MASK's dimensions, so a full-res mask beside a
        // half-res scene would write outside the scene and leave three quarters
        // of it empty. With a diffuser in front of the lens the frame is being
        // spread anyway, so the half-res mask costs nothing visible.
        let fullResMask = strength != 0 && radiusFraction <= 0 && plan == nil
        let maskWidth = fullResMask ? width : halfWidth
        let maskHeight = fullResMask ? height : halfHeight

        guard let halationMask = makeTexture(width: maskWidth, height: maskHeight),
              let output = makeTexture(width: width, height: height, storageMode: .shared),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        // The linear scene is the diffusion node's input; without the node it is
        // never allocated and the mask-only prepare kernel runs instead.
        var scene: MTLTexture?
        if plan != nil {
            guard let linear = makeTexture(width: halfWidth, height: halfHeight) else { return nil }
            scene = linear
        }

        let maskGroups = threadgroups(width: maskWidth, height: maskHeight)
        let fullGroups = threadgroups(width: width, height: height)

        // 1. Prepare: per-layer superwhite excess, and — when the diffusion node
        //    is on — the scene-linear frame it blurs, from the same decode.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            let knees = Self.halationKnees(sceneLiftStops: sceneLiftStops)
            var red = knees.x
            var green = knees.y
            var blue = knees.z
            // The mask and the ladder must be measured on the EXPOSED scene, or
            // the apply pass would add a halo taken from light the film never saw.
            var stops = exposureStops
            // The push/pull is a curve, not a flat gain: it fades to none at the
            // source's clip ceiling, so a truly clipped highlight holds at white
            // (and keeps halating) instead of being pulled into the stock's cast.
            var ceiling = Self.halationCeiling(sceneLiftStops: sceneLiftStops,
                                               headroom: halationHeadroom,
                                               highlightCeiling: highlightCeiling)
            encoder.setComputePipelineState(scene == nil ? halationMaskPipeline : scenePreparePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(halationMask, index: 1)
            if let scene {
                encoder.setTexture(scene, index: 2)
            }
            encoder.setBytes(&red, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&green, length: MemoryLayout<Float>.size, index: 1)
            encoder.setBytes(&blue, length: MemoryLayout<Float>.size, index: 2)
            encoder.setBytes(&stops, length: MemoryLayout<Float>.size, index: 3)
            encoder.setBytes(&ceiling, length: MemoryLayout<Float>.size, index: 4)
            encoder.dispatchThreadgroups(maskGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        // Radii scale with the frame so the effect looks the same at any size.
        // There is deliberately no minimum: the stock's fraction is honored as
        // given, so a small frame or a deliberately tiny debug radius really
        // diffuses less. A zero radius skips the blur entirely rather than
        // asking MPS for an invalid sigma of zero.
        let baseRadius = Float(halfWidth) * radiusFraction

        // 2. One blur per emulsion layer: red widest, then green, then blue.
        //    MPSImageGaussianBlur convolves every channel at one sigma, so the
        //    per-layer radii need three passes over the shared mask. A layer
        //    whose radius is zero is bound the mask itself (no diffusion), and
        //    with halation disabled the mask is bound directly — its energy is
        //    already multiplied by a strength of zero.
        var layerTextures = (red: halationMask, green: halationMask, blue: halationMask)
        if strength != 0, radiusFraction > 0 {
            guard let redDiffusion = makeTexture(width: maskWidth, height: maskHeight),
                  let greenDiffusion = makeTexture(width: maskWidth, height: maskHeight),
                  let blueDiffusion = makeTexture(width: maskWidth, height: maskHeight) else {
                return nil
            }
            layerTextures.red = diffuse(
                source: halationMask, destination: redDiffusion,
                radius: baseRadius * Self.redRadiusMultiplier, commandBuffer: commandBuffer
            )
            layerTextures.green = diffuse(
                source: halationMask, destination: greenDiffusion,
                radius: baseRadius * Self.greenRadiusMultiplier, commandBuffer: commandBuffer
            )
            layerTextures.blue = diffuse(
                source: halationMask, destination: blueDiffusion,
                radius: baseRadius * Self.blueRadiusMultiplier, commandBuffer: commandBuffer
            )
        }

        // 3. The lens diffusion ladder: one small separable blur per octave of
        //    the scene, combined in the apply pass.
        var diffusionLevels: [MTLTexture] = []
        var diffusionWeights = SIMD4<Float>(0, 0, 0, 0)
        if let plan, let scene {
            guard let pyramid = buildDiffusion(scene: scene, plan: plan, commandBuffer: commandBuffer) else {
                return nil
            }
            diffusionLevels = pyramid.levels
            diffusionWeights = plan.levelWeights
        }

        // 4. Blend the diffusion, add the scattered light in scene-linear, and
        //    re-encode — one full-resolution pass for both effects.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var stops = exposureStops
            var ceiling = Self.halationCeiling(sceneLiftStops: sceneLiftStops,
                                               headroom: halationHeadroom,
                                               highlightCeiling: highlightCeiling)
            var strength = strength
            var layerScale = layerScale
            var referenceSuperwhite = Self.halationReferenceSuperwhite(
                sceneLiftStops: sceneLiftStops, headroom: halationHeadroom)
            // Unused level slots are bound to a real, samplable texture rather
            // than left unbound; their weights are zero, so they contribute
            // nothing and the blend stays a normalized average.
            let fallback = diffusionLevels.first ?? layerTextures.red
            let boundLevels = (0..<4).map { index in
                index < diffusionLevels.count ? diffusionLevels[index] : fallback
            }
            var diffusionAmount = plan == nil ? 0 : diffusion.amount
            encoder.setComputePipelineState(halationApplyPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(layerTextures.red, index: 1)
            encoder.setTexture(layerTextures.green, index: 2)
            encoder.setTexture(layerTextures.blue, index: 3)
            encoder.setTexture(output, index: 4)
            for (offset, texture) in boundLevels.enumerated() {
                encoder.setTexture(texture, index: 5 + offset)
            }
            encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
            encoder.setBytes(&referenceSuperwhite, length: MemoryLayout<Float>.size, index: 2)
            encoder.setBytes(&diffusionWeights, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
            encoder.setBytes(&diffusionAmount, length: MemoryLayout<Float>.size, index: 4)
            encoder.setBytes(&stops, length: MemoryLayout<Float>.size, index: 5)
            encoder.setBytes(&ceiling, length: MemoryLayout<Float>.size, index: 6)
            encoder.dispatchThreadgroups(fullGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? output : nil
    }

    // MARK: - Lens diffusion pyramid

    /// Blur the scene-linear working frame once per ladder level, each level one
    /// octave smaller than the last, and hand back the blurred textures plus the
    /// weights the apply pass combines them with.
    ///
    /// Every level runs the SAME small kernel (`plan.taps`), because the plan
    /// divides the target sigma by the ladder depth: the reach comes from
    /// sampling a coarser level, not from a wider kernel. That is what keeps a
    /// 35-preset diffuser costing about what a small one does, and what makes the
    /// cost independent of frame size beyond the linear resolution term.
    ///
    /// The plan only returns a depth whose kernel is wider than a texel at
    /// every level (`DiffusionPlan.minLevelKernelSigma`). A shallower level
    /// would be a nearest filter here — it would reproject the texel grid, and
    /// the apply pass would upsample that grid into a flat-topped disc.
    private func buildDiffusion(
        scene: MTLTexture,
        plan: DiffusionPlan,
        commandBuffer: MTLCommandBuffer
    ) -> (levels: [MTLTexture], weights: SIMD4<Float>)? {
        var current = scene
        var blurred: [MTLTexture] = []
        blurred.reserveCapacity(plan.levels)

        for level in 0..<plan.levels {
            if level > 0 {
                let width = DiffusionPlan.levelSize(base: scene.width, level: level)
                let height = DiffusionPlan.levelSize(base: scene.height, level: level)
                guard let downsampled = makeTexture(width: width, height: height),
                      let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    return nil
                }
                encoder.setComputePipelineState(diffusionDownsamplePipeline)
                encoder.setTexture(current, index: 0)
                encoder.setTexture(downsampled, index: 1)
                encoder.dispatchThreadgroups(threadgroups(width: width, height: height),
                                             threadsPerThreadgroup: Self.groupSize)
                encoder.endEncoding()
                current = downsampled
            }

            guard let horizontal = makeTexture(width: current.width, height: current.height),
                  let vertical = makeTexture(width: current.width, height: current.height),
                  encodeBlur(from: current, to: horizontal, horizontal: true,
                             plan: plan, commandBuffer: commandBuffer),
                  encodeBlur(from: horizontal, to: vertical, horizontal: false,
                             plan: plan, commandBuffer: commandBuffer) else {
                return nil
            }
            blurred.append(vertical)
        }

        return (blurred, plan.levelWeights)
    }

    /// One axis of the per-level Gaussian. Clamped edges, precomputed normalized
    /// weights: a uniform field keeps its value at the frame border.
    private func encodeBlur(
        from source: MTLTexture,
        to destination: MTLTexture,
        horizontal: Bool,
        plan: DiffusionPlan,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var taps = UInt32(plan.taps)
        var direction = SIMD2<Int32>(horizontal ? 1 : 0, horizontal ? 0 : 1)
        encoder.setComputePipelineState(diffusionBlurPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        plan.weights.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setBytes(base, length: raw.count, index: 0)
            }
        }
        encoder.setBytes(&taps, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&direction, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
        encoder.dispatchThreadgroups(threadgroups(width: destination.width, height: destination.height),
                                     threadsPerThreadgroup: Self.groupSize)
        encoder.endEncoding()
        return true
    }

    // MARK: - Glow (post-LUT)

    /// Apply the optical-filter glow bloom to the already-graded texture and
    /// return a new texture carrying the result. `graded` is not mutated. The
    /// look is unchanged from the pre-physical-halation implementation.
    func applyGlow(
        graded: MTLTexture,
        commandQueue: MTLCommandQueue,
        strength: Float,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let halfWidth = max(1, width / 2)
        let halfHeight = max(1, height / 2)

        guard let glowMask = makeTexture(width: halfWidth, height: halfHeight),
              let glowDiffusion = makeTexture(width: halfWidth, height: halfHeight),
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
            encoder.setComputePipelineState(glowMaskPipeline)
            encoder.setTexture(graded, index: 0)
            encoder.setTexture(glowMask, index: 1)
            encoder.setBytes(&low, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&high, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(halfGroups, threadsPerThreadgroup: Self.groupSize)
            encoder.endEncoding()
        }

        // 2. Wide blur for the glow bloom, off the graded mask. Glow stays a
        //    fixed fraction of width so its look does not track stock geometry.
        let glowRadius = max(4, Float(halfWidth) * Self.glowRadiusFraction)
        blurContinuously(
            source: glowMask,
            destination: glowDiffusion,
            radius: glowRadius,
            commandBuffer: commandBuffer
        )

        // 3. Composite the tinted bloom over the graded image.
        composite(
            source: graded,
            diffusion: glowDiffusion,
            into: composited,
            strength: strength,
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

    /// Diffuse `source` into `destination` and return the texture the caller
    /// should sample. A positive `radius` (in half-resolution texels) becomes an
    /// MPS Gaussian blur; a zero radius means "no spatial diffusion" and the
    /// mask itself is returned, so the scattered energy is still added — locally
    /// — rather than the whole effect vanishing. `sigma = radius * k` is only
    /// evaluated for a strictly positive radius, so MPS is never asked for an
    /// invalid sigma of zero.
    private func diffuse(
        source: MTLTexture,
        destination: MTLTexture,
        radius: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture {
        guard radius > 0 else { return source }
        let blur = MPSImageGaussianBlur(device: device, sigma: radius * Self.blurSigmaPerRadius)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
        return destination
    }

    /// A continuous, efficient Gaussian approximation, including at 4K radii.
    /// Clamp boundaries preserve uniform highlights instead of darkening edges.
    /// Reserved for the glow path, whose radius is always positive.
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

    /// Add one blurred glow diffusion layer onto `source`, writing to `into`.
    /// A plain tinted bloom; the image's own luminance fades it out of shadows.
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

        encoder.setComputePipelineState(glowCompositePipeline)
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
