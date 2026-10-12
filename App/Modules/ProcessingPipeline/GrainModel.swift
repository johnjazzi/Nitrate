import Foundation

/// AD-9 / m00459 / m00581: the print gauge owns grain *size*; ISO owns
/// *loudness*. The gauge also scales amplitude at the fine end, because size
/// alone cannot make grain disappear — the sampling floor below pins the
/// footprint before the noise volume is undersampled.
///
/// Multipliers are documented starting points, not measurements.
enum PrintGauge: String, Codable, CaseIterable, Equatable, Sendable {
    case eightMillimetre
    case sixteenMillimetre
    case thirtyFiveMillimetre
    case seventyFiveMillimetre

    /// Multiplies the stock's grain size to reach a gauge's footprint.
    /// 35mm is the neutral 1.0 reference.
    var sizeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 2.5
        case .sixteenMillimetre: return 1.6
        case .thirtyFiveMillimetre: return 1.0
        case .seventyFiveMillimetre: return 0.55
        }
    }

    /// Scales grain amplitude independently of size. Coarse gauges are louder,
    /// 75mm is nearly silent — that is where "almost grain-free" is delivered,
    /// by amplitude, not by pushing size into the aliased regime.
    var amplitudeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 1.10
        case .sixteenMillimetre: return 1.00
        case .thirtyFiveMillimetre: return 1.00
        case .seventyFiveMillimetre: return 0.15
        }
    }

    /// Short label for the gauge selector (8mm / 16mm / 35mm / 75mm).
    var displayName: String {
        switch self {
        case .eightMillimetre: return "8mm"
        case .sixteenMillimetre: return "16mm"
        case .thirtyFiveMillimetre: return "35mm"
        case .seventyFiveMillimetre: return "75mm"
        }
    }

    /// The neutral gauge: identity size and amplitude.
    static let neutral: PrintGauge = .thirtyFiveMillimetre
}

/// Pure grain math shared by the Metal kernel and the CPU-side uniforms so the
/// two axes stay separable and unit-testable without a GPU.
enum GrainModel {
    /// Kodak diffuse RMS granularity reference: the 50D anchor.
    static let isoReference: Float = 50
    /// σD ∝ ISO^0.46. Speed rises with crystal projected area and σD ∝ √area,
    /// so σD ∝ √speed — a 10× ISO change gives 2.86× σD, not 10×.
    static let isoLoudnessExponent: Float = 0.46
    static let baseAmount: Float = 0.55
    /// Below footprint ≈ 1.0 the 128³ volume is undersampled: lag-1 correlation
    /// collapses and finer size yields aliased noise, not finer grain. Floor the
    /// effective size so the axis cannot reach the aliased regime.
    static let footprintFloor: Float = 0.95
    static let footprintCeiling: Float = 8.0

    /// Sublinear ISO loudness, normalized so ISO 50 → 1.0.
    static func isoLoudness(iso: Float) -> Float {
        let safe = iso.isFinite && iso > 0 ? iso : isoReference
        return pow(safe / isoReference, isoLoudnessExponent)
    }

    /// Effective footprint: stock size × gauge size, clamped off the sampling
    /// floor. At 75mm on a 1.3 stock this is 1.3 × 0.55 = 0.715 → floored to
    /// 0.95. The remaining graininess at 75mm is removed by the 0.15 amplitude
    /// multiplier, not by pushing size further into the aliased zone.
    static func effectiveSize(stockGrainSize: Float, gauge: PrintGauge) -> Float {
        let safeStock = stockGrainSize.isFinite && stockGrainSize > 0 ? stockGrainSize : 1.0
        return min(max(safeStock * gauge.sizeMultiplier, footprintFloor), footprintCeiling)
    }

    /// Composition rule: amount = 0.55 · isoLoudness · gaugeAmplitude · edgeFactor.
    static func amount(iso: Float, gauge: PrintGauge, edgeFactor: Float = 1.0) -> Float {
        baseAmount * isoLoudness(iso: iso) * gauge.amplitudeMultiplier * edgeFactor
    }
}
