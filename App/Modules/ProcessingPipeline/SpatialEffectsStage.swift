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

    /// Per-layer halation onsets, in STOPS above diffuse white: the brightness at
    /// which that layer starts to scatter.
    ///
    /// Red is re-exposed by the least scattered light and blue by the most, so
    /// red comes on first — that ordering is what makes a faint halo read red and
    /// a bright one read white, and it must never be permuted. The value is the
    /// DELIVERED onset, i.e. the level in the picture the operator looks at, so
    /// the dial is legible on its own terms: 0 is diffuse white and Apple Log 2
    /// clips at +3.58.
    ///
    /// Stops rather than multiples of white because the response is logarithmic
    /// in light: one dial step is one stop brighter wherever it sits in the
    /// range, and the ramp from an onset to its reference is linear in stops, not
    /// in light (see `spatial_halation_energy`). The old form — a knee in white
    /// multiples with growth linear in light — spent most of its span near the
    /// top, so a highlight appeared to do nothing and then saturate.
    /// Authored from an outdoor scene in the debug sheet: these are the onsets that
    /// read most natural on real light, and they sit about a stop and a half above
    /// the earlier authored set, so an ordinary sunlit surface has to climb a
    /// little further before it scatters. Red comes on first, then green, then
    /// blue, and the ramp each layer runs from its onset up to the reference is the
    /// same length in stops.
    private static let redOnsetStops: Float = 0.2000    // 1.15x diffuse white
    private static let greenOnsetStops: Float = 1.2000  // 2.30x
    private static let blueOnsetStops: Float = 2.1000   // 4.29x

    /// Where a layer reaches FULL contribution: 10x diffuse white, ONE value for
    /// stills and takes alike.
    ///
    /// Apple Log 2 records to about 12x white (`appleLog2ClipWhite`), so 10x sits
    /// inside the recorded range and leaves room for an 11x specular without
    /// letting it swamp the graded frame. Both ends of the ramp are authored on
    /// the same scale, so a still and a take of one scene grade the same way
    /// whatever the file's own baseline exposure — that invariance is the point
    /// of expressing the ramp in stops rather than in measured white multiples.
    static let halationReferenceStops: Float = 3.3219    // log2(10)

    /// Apple Log 2's recorded range tops out near 12x diffuse white (code 1.0
    /// decodes to ~12.0), so a video frame is truly clipped there. See the
    /// superwhite note in `spatial.metal`.
    static let appleLog2ClipWhite: Float = 12.0

    /// The authored onsets, for a caller that wants to seed a dial from them.
    static var authoredOnsets: SIMD3<Float> {
        SIMD3(redOnsetStops, greenOnsetStops, blueOnsetStops)
    }

    /// The onsets a frame is measured against.
    ///
    /// Path-independent by construction. A still's decode lift and a take's
    /// capture held under both move the FRAME, not the onset, and
    /// `frameWhiteStops` carries them — so the numbers here are the delivered
    /// onsets for stills and takes alike, which is what lets one scene grade the
    /// same way through either path.
    ///
    /// `authored` replaces the constants, for the debug sheet's onset dials;
    /// every shipping path passes nil.
    static func halationOnsets(authored: SIMD3<Float>? = nil) -> SIMD3<Float> {
        let onsets = authored ?? authoredOnsets
        return SIMD3(clampOnset(onsets.x), clampOnset(onsets.y), clampOnset(onsets.z))
    }

    /// Where the frame being measured sits relative to the DELIVERED picture, in
    /// stops.
    ///
    /// A diffuse white surface delivers at 1.0 — the develop lift is the stop the
    /// capture was held under, put back — so a take is measured on a frame a stop
    /// darker than the picture (−1), and a still whose decode was lifted N stops
    /// is measured N stops above that (−1 + N). This one additive offset replaces
    /// the multiplicative knee and reference scaling the model used to need, and
    /// it is the only place the two paths differ.
    static func frameWhiteStops(sceneLiftStops: Float) -> Float {
        let lift = sceneLiftStops.isFinite ? max(-8, min(8, sceneLiftStops)) : 0
        let capture = SystemExposureScheme.captureStops.isFinite ? SystemExposureScheme.captureStops : 0
        return capture + lift
    }

    private static func clampOnset(_ stops: Float) -> Float {
        guard stops.isFinite else { return 0 }
        return max(-6, min(halationReferenceStops, stops))
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
    /// (see `RAWPhotoDecoder.measureHeadroom`), a take at its `highlightCeiling`.
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
        /// The per-layer onsets to measure against instead of the stage's own
        /// constants, in stops above diffuse white, for the debug sheet's dials.
        /// Nil on every shipping path: the onsets are a rule there, not a
        /// per-frame choice. The values ARE the delivered onsets — the frame's own
        /// offset is applied separately, through `frameWhiteStops` — so a dial
        /// value can be pasted straight into the constants above.
        authoredOnsets: SIMD3<Float>? = nil,
        /// Measured highlight ceiling of a still, in lifted units, used by the
        /// push/pull hold. Nil for video, which hands over its own measured
        /// `highlightCeiling` instead. See `halationCeiling`. The halo's own
        /// reference is authored and takes no measurement from here.
        halationHeadroom: Float? = nil,
        /// The take's own highlight ceiling, in the frame's scene units, measured
        /// from the source frames. A take's halation ramp stays authored (see
        /// `halationReferenceStops`), but the push/pull hold must anchor to what
        /// THIS take carries: a hazy sky tops out near 3x white, and a hold
        /// anchored at Apple Log 2's 12x would let a pull drag it down into the
        /// stock's cast. Nil for a still, which measures its own `halationHeadroom`.
        highlightCeiling: Float? = nil,
        /// Render-time exposure in stops, applied to the scene BEFORE the emulsion
        /// stages: a video take is locked to its shutter, so the operator pulls a
        /// bright day down in the render, and halation has to be measured against
        /// the light the film actually receives. Stills pass 0 — their exposure is
        /// baked into the decode.
        exposureStops: Float = 0,
        /// The system's develop lift, in stops, applied to the scene AFTER the
        /// halation and diffusion stages and before the encode that feeds the
        /// stock LUT. This is where the stop the camera captured under is put
        /// back; see `SystemExposureScheme`. Unlike `exposureStops` it is a flat
        /// gain, and it is deliberately not applied to the halation mask: the
        /// emulsion has to scatter the light it actually received.
        postEmulsionStops: Float = 0,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let plan = diffusion.plan(sourceWidth: width)
        // Only all three disabled means byte-for-byte identity, including Log noise.
        guard strength != 0 || plan != nil || exposureStops != 0 || postEmulsionStops != 0 else { return source }

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

        // 1. Prepare: the per-layer halation mask, and — when the diffusion node
        //    is on — the scene-linear frame it blurs, from the same decode.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            let onsets = Self.halationOnsets(authored: authoredOnsets)
            var red = onsets.x
            var green = onsets.y
            var blue = onsets.z
            // The mask and the ladder must be measured on the EXPOSED scene, or
            // the apply pass would add a halo taken from light the film never saw.
            var stops = exposureStops
            // The push/pull is a curve, not a flat gain: it fades to none at the
            // source's clip ceiling, so a truly clipped highlight holds at white
            // (and keeps halating) instead of being pulled into the stock's cast.
            var ceiling = Self.halationCeiling(sceneLiftStops: sceneLiftStops,
                                               headroom: halationHeadroom,
                                               highlightCeiling: highlightCeiling)
            var referenceStops = Self.halationReferenceStops
            // Where this frame sits relative to the picture it will deliver, so
            // the onsets above are read on one scale whatever the capture held
            // under or the decode lifted.
            var frameWhite = Self.frameWhiteStops(sceneLiftStops: sceneLiftStops)
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
            encoder.setBytes(&referenceStops, length: MemoryLayout<Float>.size, index: 5)
            encoder.setBytes(&frameWhite, length: MemoryLayout<Float>.size, index: 6)
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
            var lift = postEmulsionStops
            var ceiling = Self.halationCeiling(sceneLiftStops: sceneLiftStops,
                                               headroom: halationHeadroom,
                                               highlightCeiling: highlightCeiling)
            var strength = strength
            var layerScale = layerScale
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
            encoder.setBytes(&diffusionWeights, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            encoder.setBytes(&diffusionAmount, length: MemoryLayout<Float>.size, index: 3)
            encoder.setBytes(&stops, length: MemoryLayout<Float>.size, index: 4)
            encoder.setBytes(&ceiling, length: MemoryLayout<Float>.size, index: 5)
            encoder.setBytes(&lift, length: MemoryLayout<Float>.size, index: 6)
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
