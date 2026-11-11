import Foundation
import simd

/// Lens diffusion ("mist") node: presets, authored settings, and the CPU-side
/// blur plan the shaders execute.
///
/// Radii are authored in PIXELS AT A 1080p-WIDE FRAME and scaled with the real
/// frame, so a preset keeps its size relative to the picture instead of
/// shrinking on a 4K capture. `sigma = radius / 2` — the blur is visibly spread
/// to roughly the stated radius.
///
/// The node runs in scene-linear light, before the stock LUT, because a
/// diffusion filter scatters light in front of the lens. That is the same domain
/// as halation, which is why the two share one decode/encode pass
/// (`spatial_halation_apply`).
enum DiffusionPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case radius4
    case radius8
    case radius16
    case radius35
    case radius75

    var id: String { rawValue }

    /// Radius in pixels at a 1080p-wide frame; `nil` when the node is bypassed.
    ///
    /// `radius75` is registered so the ladder can be compared end to end, but it
    /// is bypassed rather than rendered: at that reach the blur is no longer the
    /// expensive part of judging the look, and paying for it before the three
    /// smaller presets are settled is wasted frame time.
    var radiusPixels: Float? {
        switch self {
        case .off, .radius75: return nil
        case .radius4: return 4
        case .radius8: return 8
        case .radius16: return 16
        case .radius35: return 35
        }
    }

    var isBypass: Bool { radiusPixels == nil }

    var title: String {
        switch self {
        case .off: return "Off"
        case .radius4: return "4"
        case .radius8: return "8"
        case .radius16: return "16"
        case .radius35: return "35"
        case .radius75: return "75"
        }
    }

    /// Readout label that states the bypass instead of implying a look.
    var detail: String {
        guard let radiusPixels else { return "bypassed" }
        return String(format: "%.0f px @1080p", radiusPixels)
    }
}

/// Where the radius numbers come from.
///
/// The ladder is not a taste table: it follows the measured light scatter of the
/// emulsion, scaled by how much each format has to be enlarged to fill the same
/// delivered frame. A 16mm negative is enlarged ~3.5x more than a 35mm one, so
/// the SAME physical scatter in the emulsion lands 3.5x wider in the picture —
/// which is why 16mm and 8mm read softer than 35mm without pretending the
/// smaller emulsions scatter light differently.
///
/// Measured inputs, both from published film-stock work rather than invented
/// here:
///
///  * **Scatter radius.** Photographic emulsion spread functions have a core of
///    a few micrometres plus a base-reflection halo out to tens of micrometres;
///    20 um is the working figure for "the light that leaves a highlight and
///    lands somewhere else" (ENS Louis-Lumiere's film-texture study puts the
///    emulsion's own scattering at roughly 2 pixels of a 35mm scan, which is
///    ~13 um — the same order).
///  * **Negative width.** Widths are the standard image areas, not the film
///    stock: Super 8 5.79 mm, 16mm 10.26 mm, 35mm still 36 mm, 65mm 5-perf
///    52.5 mm.
///
/// One authored constant remains, `filterGain`, because a 20 um scatter on 35mm
/// is ~1 pixel at a 1080p delivery — physically true and visually invisible. A
/// diffusion node on 35mm is a FILTER (the Pro-Mist class), not the emulsion
/// alone, and a filter scatters far wider than silver halide does. The gain is
/// the one place taste is allowed to act, and it is deliberately a single
/// number: change it and every gauge moves together, in physically correct
/// proportion.
enum DiffusionPhysics {
    /// Radius of the light scatter itself, in micrometres at the negative.
    static let scatterRadiusMicrometres: Float = 20
    /// Multiplier taking the emulsion's own scatter to a lens diffusion filter's
    /// spread. 4x lands 35mm at ~4 px, 16mm at ~15 px and 8mm at ~26 px on a
    /// 1080p frame.
    static let filterGain: Float = 4
    /// Width of the delivered reference frame the radii are expressed against.
    static let referenceWidthPixels: Float = 1920

    /// Standard image width of each format's negative, in millimetres.
    static func negativeWidthMillimetres(_ gauge: PrintGauge) -> Float {
        switch gauge {
        case .eightMillimetre: return 5.79        // Super 8 image area
        case .sixteenMillimetre: return 10.26     // 16mm (10.26 x 7.49)
        case .thirtyFiveMillimetre: return 36     // 35mm still, full frame
        case .seventyFiveMillimetre: return 52.5  // 65mm 5-perf
        }
    }

    /// Enlargement of one format relative to 35mm, which is what makes a smaller
    /// negative look softer at the same delivered size.
    static func enlargementRelativeTo35mm(_ gauge: PrintGauge) -> Float {
        negativeWidthMillimetres(.thirtyFiveMillimetre) / negativeWidthMillimetres(gauge)
    }

    /// Radius, in reference-frame pixels, that this format's scatter lands at.
    static func radiusPixels(_ gauge: PrintGauge) -> Float {
        let scatterMillimetres = scatterRadiusMicrometres / 1000
        let fraction = scatterMillimetres / negativeWidthMillimetres(gauge)
        return fraction * referenceWidthPixels * filterGain
    }

    /// The ladder rung this format rounds to. Rungs are the shipped presets;
    /// 75mm is bypassed rather than rounded, because the reference print does
    /// not diffuse.
    static func preset(for gauge: PrintGauge) -> DiffusionPreset {
        if gauge == .seventyFiveMillimetre { return .radius75 }
        let radius = radiusPixels(gauge)
        return DiffusionPreset.allCases
            .filter { $0.radiusPixels != nil && !$0.isBypass }
            .min { abs(($0.radiusPixels ?? 0) - radius) < abs(($1.radiusPixels ?? 0) - radius) }
            ?? .radius8
    }
}

/// Authored diffusion settings for one render.
///
/// `amount` is how far the scene light moves toward the diffused version: 0 is
/// an exact pass-through, 1 is fully diffused. It is deliberately separate from
/// the preset, so radius (the filter) and strength (how much of the frame it
/// owns) can be judged independently on one frame.
struct DiffusionSettings: Equatable, Sendable, Codable {
    var preset: DiffusionPreset
    var amount: Float

    static let disabled = DiffusionSettings(preset: .off, amount: 0)

    init(preset: DiffusionPreset = .off, amount: Float = 0.5) {
        self.preset = preset
        self.amount = amount
    }

    /// Legacy stocks have no diffusion key at all; a missing field is a disabled
    /// node, never a default look.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? values.decodeIfPresent(DiffusionPreset.self, forKey: .preset)) ?? .off
        amount = (try? values.decodeIfPresent(Float.self, forKey: .amount)) ?? 0
    }

    /// True when the shader has anything to do. A bypassed preset and a zero
    /// amount both mean "do not allocate, do not blur, do not even decode".
    var isEnabled: Bool {
        preset.radiusPixels != nil && amount > 0 && amount.isFinite
    }

    /// The blur this setting resolves to at one frame width, or nil when the
    /// node is disabled. Nil is the common case and allocates nothing.
    func plan(sourceWidth: Int) -> DiffusionPlan? {
        guard isEnabled, let radiusPixels = preset.radiusPixels, sourceWidth > 0 else { return nil }
        // radius (1080p px) -> sigma (1080p px) -> sigma at this width -> sigma
        // on the HALF-RESOLUTION working buffer the stage blurs on.
        let sigmaPixels = radiusPixels * 0.5
        let sigmaLevelZero = sigmaPixels * Float(sourceWidth) / DiffusionPlan.referenceWidth / 2
        return DiffusionPlan.make(sigmaLevelZero: sigmaLevelZero)
    }
}

/// The multi-scale Gaussian the diffusion node executes.
///
/// A direct separable Gaussian of sigma 8.75 (the 35 preset at 1080p) needs ~27
/// taps per axis, per pass, and the taps grow with resolution — the wide
/// presets would cost more than the rest of the pipeline together. Instead the
/// blur is a GAUSSIAN MIXTURE spread over a pyramid:
///
///  * level `k` is the scene downsamped `k` octaves, blurred with a small
///    separable kernel, then sampled back up at full working resolution;
///  * every level uses the SAME kernel (its sigma is constant across the
///    ladder), so the tap count is bounded by `maxTaps` no matter how wide the
///    preset is;
///  * the level weights are chosen so the mixture's variance equals the target
///    Gaussian's, which is what makes the result behave like one wide blur
///    rather than the sum of unrelated blurs.
///
/// A level is only a blur if that kernel spans MORE THAN ONE of the level's own
/// texels (see `minLevelKernelSigma`). Narrower than that and the separable
/// pass is a nearest filter: the level returns its texel grid, the bilinear
/// upsample turns each texel into a flat plateau, and the "blur" the ladder
/// delivers is a stack of texel-sized boxes with hard edges — which is exactly
/// what a diffuser never does. The depth is therefore bounded by the kernel as
/// well as by the tap budget.
///
/// The small radii therefore run as a single direct separable pass, and the wide
/// ones reach through the pyramid — the hybrid the two halves of the ladder each
/// want.
struct DiffusionPlan: Equatable, Sendable {
    /// Deepest ladder the node will build. Beyond four octaves the extra levels
    /// stop buying reach and start costing command-buffer dispatches.
    static let maxLevels = 4
    /// Hard cap on taps per axis per pass; the kernel truncates and renormalizes.
    static let maxTaps = 33
    /// Least kernel sigma, in a level's OWN texels, that still reads as a blur.
    ///
    /// Every level runs the same kernel, so a level only averages its own grid
    /// if that kernel spans more than a texel of it. Below one texel the
    /// separable pass is a nearest filter: the level hands its texel grid back
    /// unchanged, bilinear upsampling turns each texel into a flat plateau with
    /// a hard edge, and the summed ladder answers an isolated highlight with a
    /// stack of blocky discs instead of a smooth radial scatter. The ladder is
    /// therefore only allowed to reach as deep as this permits — a deeper one
    /// that cannot afford a real kernel is not cheaper, it is wrong.
    static let minLevelKernelSigma: Float = 1.25
    /// Width the authored radii are expressed at.
    static let referenceWidth: Float = 1920

    let levels: Int
    let taps: Int
    /// Gaussian tap weights for one axis, normalized to 1.
    let weights: [Float]
    /// Per-level combine weights in level order (near, mid, far, farthest);
    /// unused slots are zero. Normalized to 1.
    let levelWeights: SIMD4<Float>
    /// Sigma requested at EVERY level, in that level's own texels.
    let kernelSigma: Float
    /// Aggregate sigma the ladder actually delivers, at level 0 (half-res)
    /// texels. Truncation at `maxTaps` narrows the realized blur, so this is
    /// what the readouts and tests report rather than the request.
    let realizedSigmaLevelZero: Float

    /// Relative variance carried by each level, widest last. The widest level is
    /// the cheapest per texel, so it carries most of the spread; the narrow
    /// levels keep the wide blur from replacing all fine structure.
    private static let weightLadders: [[Float]] = [
        [1.0],
        [0.30, 0.70],
        [0.15, 0.30, 0.55],
        [0.10, 0.20, 0.30, 0.40]
    ]

    static func make(sigmaLevelZero sigma: Float) -> DiffusionPlan {
        let target = max(sigma, 0.35)
        var chosen = (levels: 1, kernelSigma: target, taps: tapCount(for: target), cost: Float.greatestFiniteMagnitude)

        for levels in 1...maxLevels {
            // Level k delivers sigma * 2^(k - (levels-1)) at level 0, so each
            // level's OWN kernel sigma is the same: target / 2^(levels-1).
            let ladder = weightLadders[levels - 1]
            let variance = ladder.enumerated().reduce(Float(0)) { total, entry in
                let ratio = powf(2, Float(entry.offset - (levels - 1)))
                return total + entry.element * ratio * ratio
            }
            let correction = 1 / variance.squareRoot()
            let kernelSigma = correction * target / powf(2, Float(levels - 1))
            // A level whose kernel is narrower than its own texel is not a
            // blur at all; see `minLevelKernelSigma`. The depth is bounded by
            // that, not by the tap count.
            guard kernelSigma >= minLevelKernelSigma else { continue }
            let taps = tapCount(for: kernelSigma)
            let cost = perPixelCost(taps: taps, levels: levels)
            if cost < chosen.cost {
                chosen = (levels, kernelSigma, taps, cost)
            }
        }

        let ladder = weightLadders[chosen.levels - 1]
        var levelWeights = SIMD4<Float>(0, 0, 0, 0)
        for (index, weight) in ladder.enumerated() {
            levelWeights[index] = weight
        }

        let weights = gaussianWeights(sigma: chosen.kernelSigma, taps: chosen.taps)
        let kernelSigmaRealized = discreteSigma(weights)
        var aggregate: Float = 0
        for index in 0..<chosen.levels {
            let reach = kernelSigmaRealized * powf(2, Float(index))
            aggregate += ladder[index] * reach * reach
        }

        return DiffusionPlan(
            levels: chosen.levels,
            taps: chosen.taps,
            weights: weights,
            levelWeights: levelWeights,
            kernelSigma: chosen.kernelSigma,
            realizedSigmaLevelZero: aggregate.squareRoot()
        )
    }

    /// Aggregate sigma expressed back in 1080p-reference pixels.
    func sigmaPixels(atSourceWidth width: Int) -> Float {
        guard width > 0 else { return 0 }
        return realizedSigmaLevelZero * 2 * Self.referenceWidth / Float(width)
    }

    /// Aggregate radius (2 sigma) in 1080p-reference pixels.
    func radiusPixels(atSourceWidth width: Int) -> Float {
        sigmaPixels(atSourceWidth: width) * 2
    }

    /// Destination size of one ladder level, for a level-0 working size.
    static func levelSize(base: Int, level: Int) -> Int {
        max(1, base >> level)
    }

    // MARK: - Taps and weights

    static func tapCount(for sigma: Float) -> Int {
        let reach = max(1, Int(ceilf(3 * sigma)))
        return min(2 * reach + 1, maxTaps)
    }

    /// Truncated Gaussian, normalized over the taps that survive the cap.
    /// Normalizing (rather than dropping the tail's energy) is what keeps a
    /// uniform field uniform after each pass.
    static func gaussianWeights(sigma: Float, taps: Int) -> [Float] {
        let middle = taps / 2
        var weights = [Float](repeating: 0, count: taps)
        var total: Float = 0
        for index in 0..<taps {
            let offset = Float(index - middle)
            let weight = expf(-(offset * offset) / (2 * sigma * sigma))
            weights[index] = weight
            total += weight
        }
        return weights.map { $0 / total }
    }

    /// Second moment of the discrete, normalized kernel: the sigma it really
    /// delivers once the tails are truncated.
    private static func discreteSigma(_ weights: [Float]) -> Float {
        let middle = weights.count / 2
        let variance = weights.enumerated().reduce(Float(0)) { total, entry in
            let offset = Float(entry.offset - middle)
            return total + entry.element * offset * offset
        }
        return variance.squareRoot()
    }

    /// Rough taps of work per level-0 pixel: the separable pair weighted by each
    /// level's area, plus one downsample per extra level. Used only to choose
    /// the ladder, so the constant term for the downsample is an estimate.
    private static func perPixelCost(taps: Int, levels: Int) -> Float {
        var cost: Float = 0
        for level in 0..<levels {
            cost += 2 * Float(taps) * powf(0.25, Float(level))
        }
        return cost + Float(levels - 1)
    }
}
