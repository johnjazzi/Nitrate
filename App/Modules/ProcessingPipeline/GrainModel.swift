import Foundation

/// AD-9 / m00459 / m00581, revised: the print gauge owns grain entirely — both
/// *size* (footprint) and *presence* (amplitude). ISO is the exposure index and
/// does not scale grain.
///
/// The ladder is deliberately fine. `footprintFloor` is a guard against
/// degenerate stock sizes (zero, negative, non-finite) and keeps the volume
/// sample coordinate bounded; it is **not** an undersampling guarantee. A
/// footprint below roughly one texel of the 128³ volume does lose lag-1 spatial
/// correlation — neighbouring pixels draw from nearly independent parts of the
/// field — and the requested fine-end tuning produces finer, less
/// correlated grain. Only the amplitude multiplier makes a gauge read quieter.
///
/// Multipliers are documented starting points, not measurements.
enum PrintGauge: String, Codable, CaseIterable, Equatable, Sendable {
    case eightMillimetre = "8mm"
    case sixteenMillimetre = "16mm"
    case thirtyFiveMillimetre = "35mm"
    case seventyFiveMillimetre = "75mm"

    /// Multiplies the stock's grain size to reach a gauge's footprint.
    ///
    /// Tuned in the debug single-frame mode with size and presence decoupled:
    /// size — not presence — is what makes a coarse gauge read as coarse. This is
    /// the previous ladder (4.0 / 2.7 / 1.8 / 1.0) halved, so every stock and
    /// gauge lands on exactly half its previous effective footprint.
    var sizeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 2.0
        case .sixteenMillimetre: return 1.35
        case .thirtyFiveMillimetre: return 0.9
        case .seventyFiveMillimetre: return 0.5
        }
    }

    /// Scales grain presence. Coarse gauges are louder, 75mm is nearly silent —
    /// that is where "almost grain-free" is delivered, by amplitude, not by
    /// the finer footprint alone.
    var amplitudeMultiplier: Float {
        switch self {
        case .eightMillimetre: return 0.50
        case .sixteenMillimetre: return 0.36
        case .thirtyFiveMillimetre: return 0.27
        case .seventyFiveMillimetre: return 0.15
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

    /// The gauge a render falls back to when none is selected: 35mm, the middle
    /// of the ladder and the standard look.
    static let neutral: PrintGauge = .thirtyFiveMillimetre
}

/// Pure grain math shared by the Metal kernel and the CPU-side uniforms so the
/// gauge's two axes stay unit-testable without a GPU.
enum GrainModel {
    /// Single loudness scale: presence is `baseAmount · gaugeAmplitude`. There is
    /// no ISO term — ISO is exposure only. Raised 10% (0.55 → 0.605) with the
    /// half-size ladder so the finer grain keeps its presence.
    static let baseAmount: Float = 0.605
    /// Lower bound on the effective footprint. It rejects degenerate stock sizes
    /// and keeps the volume sample coordinate bounded; it deliberately does NOT
    /// claim the footprint stays above the volume's own texel scale. Under ~1
    /// texel an output pixel advances through more than one volume texel, so the
    /// field's texel-scale detail falls below a pixel: neighbouring pixels draw
    /// from nearly independent parts of the field, lag-1 correlation drops and
    /// the grain reads finer and flatter. That is the requested fine end — finer
    /// size at the cost of spatial correlation — not an anti-aliasing guarantee.
    static let footprintFloor: Float = 0.475
    /// Ceiling for the coarse end, halved alongside the 8mm multiplier so the
    /// coarse gauge is not silently clipped back to a smaller footprint.
    static let footprintCeiling: Float = 8.0

    /// Effective footprint: stock size x gauge size, held between the model's
    /// absolute bounds. Inside those bounds the footprint is exactly what the
    /// stock and gauge ask for; at the fine end that is under one texel of the
    /// 128³ volume on purpose (see `footprintFloor`).
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
