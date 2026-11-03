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
        case .radius8: return 8
        case .radius16: return 16
        case .radius35: return 35
        }
    }

    var isBypass: Bool { radiusPixels == nil }

    var title: String {
        switch self {
        case .off: return "Off"
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
/// The small radii therefore run as a single direct separable pass, and the wide
/// ones reach through the pyramid — the hybrid the two halves of the ladder each
/// want.
struct DiffusionPlan: Equatable, Sendable {
    /// Deepest ladder the node will build. Beyond four octaves the extra levels
    /// stop buying reach and start costing command-buffer dispatches.
    static let maxLevels = 4
    /// Hard cap on taps per axis per pass; the kernel truncates and renormalizes.
    static let maxTaps = 33
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
