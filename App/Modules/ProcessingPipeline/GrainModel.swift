import Foundation

/// AD-9 / m00459 / m00581, revised: the print gauge owns grain entirely — both
/// *size* (footprint) and *presence* (amplitude). ISO is the exposure index and
/// does not scale grain. Size alone cannot make grain disappear, because the
/// sampling floor below pins the footprint before the noise volume is
/// undersampled, so the fine end is delivered by the amplitude multiplier.
///
/// Multipliers are documented starting points, not measurements.
enum PrintGauge: String, Codable, CaseIterable, Equatable, Sendable {
    case eightMillimetre = "8mm"
    case sixteenMillimetre = "16mm"
    case thirtyFiveMillimetre = "35mm"
    case seventyFiveMillimetre = "75mm"

    /// Multiplies the stock's grain size to reach a gauge's footprint. 35mm is
    /// the identity 1.0 reference.
    ///
    /// The one-rung-finer slide was reverted: 35mm came out far too subtle and
    /// 8mm not coarse enough, and the fix belongs on this axis rather than on
    /// presence. Only size was reverted — presence keeps its trimmed values.
    var sizeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 3.0
        case .sixteenMillimetre: return 1.8
        case .thirtyFiveMillimetre: return 1.0
        case .seventyFiveMillimetre: return 0.55
        }
    }

    /// Scales grain presence. Coarse gauges are louder, 75mm is nearly silent —
    /// that is where "almost grain-free" is delivered, by amplitude, not by
    /// pushing size into the aliased regime.
    var amplitudeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 1.00
        case .sixteenMillimetre: return 0.95
        case .thirtyFiveMillimetre: return 0.14
        case .seventyFiveMillimetre: return 0.04
        }
    }

    /// Short label for the gauge selector; the encoded value is the same short
    /// form, so exported metadata reads "35mm", not "thirtyFiveMillimetre".
    var displayName: String { rawValue }

    /// Accept both the current short values ("8mm") and the legacy long case
    /// names ("eightMillimetre") that earlier builds persisted. Without this a
    /// stored render queue written before the rename fails to decode and the
    /// whole queue is reported as unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let gauge = PrintGauge(rawValue: raw) {
            self = gauge
            return
        }
        switch raw {
        case "eightMillimetre": self = .eightMillimetre
        case "sixteenMillimetre": self = .sixteenMillimetre
        case "thirtyFiveMillimetre": self = .thirtyFiveMillimetre
        case "seventyFiveMillimetre": self = .seventyFiveMillimetre
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown print gauge: \(raw)"
            ))
        }
    }

    /// The reference gauge: 35mm carries the stock's authored grain size (size
    /// multiplier 1.0), so it is what a render falls back to when no gauge is
    /// selected.
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
        effectiveSize(stockGrainSize: stockGrainSize, sizeMultiplier: gauge.sizeMultiplier)
    }

    /// Effective footprint from an explicit size multiplier. The debug sheet
    /// uses this so size can be dialled without also moving presence.
    static func effectiveSize(stockGrainSize: Float, sizeMultiplier: Float) -> Float {
        let safeStock = stockGrainSize.isFinite && stockGrainSize > 0 ? stockGrainSize : 1.0
        let safeMultiplier = sizeMultiplier.isFinite && sizeMultiplier > 0 ? sizeMultiplier : 1.0
        return min(max(safeStock * safeMultiplier, footprintFloor), footprintCeiling)
    }

    /// Composition rule: amount = baseAmount x gaugeAmplitude x edgeFactor.
    /// The gauge owns presence; ISO does not scale grain.
    static func amount(gauge: PrintGauge, edgeFactor: Float = 1.0) -> Float {
        baseAmount * gauge.amplitudeMultiplier * edgeFactor
    }
}
