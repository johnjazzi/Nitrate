import Foundation

/// AD-9 / m00459 / m00581, revised: the print gauge owns grain entirely — both
/// *size* (footprint) and *presence* (amplitude). ISO is the exposure index and
/// does not scale grain. Size alone cannot make grain disappear, because the
/// sampling floor below pins the footprint before the noise volume is
/// undersampled, so the fine end is delivered by the amplitude multiplier.
///
/// Multipliers are documented starting points, not measurements.
enum PrintGauge: String, Codable, CaseIterable, Equatable, Sendable {
    case eightMillimetre
    case sixteenMillimetre
    case thirtyFiveMillimetre
    case seventyFiveMillimetre

    /// Multiplies the stock's grain size to reach a gauge's footprint. 35mm is
    /// the neutral 1.0 reference. Coarse gauges must be *visibly* coarser, not a
    /// token step: 8mm is 6x the neutral footprint (2.5x read as "too small" on
    /// device).
    var sizeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 6.0
        case .sixteenMillimetre: return 3.0
        case .thirtyFiveMillimetre: return 1.0
        case .seventyFiveMillimetre: return 0.55
        }
    }

    /// Scales grain presence. Coarse gauges are louder, 75mm is nearly silent —
    /// that is where "almost grain-free" is delivered, by amplitude, not by
    /// pushing size into the aliased regime.
    var amplitudeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 1.30
        case .sixteenMillimetre: return 1.10
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
/// gauge's two axes stay unit-testable without a GPU.
enum GrainModel {
    /// Single loudness scale: presence is `baseAmount · gaugeAmplitude`. There is
    /// no ISO term — ISO is exposure only.
    static let baseAmount: Float = 0.55
    /// Below footprint ~1.0 the 128-cubed volume is undersampled: lag-1
    /// correlation collapses and finer size yields aliased noise, not finer
    /// grain. Floor the effective size so the axis cannot reach that regime.
    static let footprintFloor: Float = 0.95
    /// Ceiling for the coarse end. Raised alongside the 8mm multiplier so the
    /// coarse gauge is not silently clipped back to a small footprint.
    static let footprintCeiling: Float = 16.0

    /// Effective footprint: stock size x gauge size, clamped off the sampling
    /// floor. At 75mm on a 1.3 stock this is 1.3 x 0.55 = 0.715 -> floored to
    /// 0.95. The remaining graininess at 75mm is removed by the 0.15 amplitude
    /// multiplier, not by pushing size further into the aliased zone.
    static func effectiveSize(stockGrainSize: Float, gauge: PrintGauge) -> Float {
        let safeStock = stockGrainSize.isFinite && stockGrainSize > 0 ? stockGrainSize : 1.0
        return min(max(safeStock * gauge.sizeMultiplier, footprintFloor), footprintCeiling)
    }

    /// Composition rule: amount = baseAmount x gaugeAmplitude x edgeFactor.
    /// The gauge owns presence; ISO does not scale grain.
    static func amount(gauge: PrintGauge, edgeFactor: Float = 1.0) -> Float {
        baseAmount * gauge.amplitudeMultiplier * edgeFactor
    }
}
