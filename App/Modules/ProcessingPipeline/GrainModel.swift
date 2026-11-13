import Foundation

/// AD-9 / m00459 / m00581, revised: the print gauge owns grain entirely — both
/// *size* (footprint) and *presence* (amplitude). ISO is the exposure index and
/// does not scale grain. Size alone cannot make grain disappear, because the
/// sampling floor below pins the footprint before the noise volume is
/// undersampled, so the fine end is delivered by the amplitude multiplier.
///
/// The ladder is configuration, not code: `gauges.json` ships one entry per print
/// gauge and the multiplier properties below delegate to it. A gauge only
/// scales the stock's grain size; stock `grainSize` itself is never rewritten.
///
/// Multipliers are documented starting points, not measurements.
enum PrintGauge: String, Codable, CaseIterable, Equatable, Sendable {
    case eightMillimetre = "8mm"
    case sixteenMillimetre = "16mm"
    case thirtyFiveMillimetre = "35mm"
    case seventyFiveMillimetre = "75mm"

    /// Multiplies the stock's grain size to reach a gauge's footprint.
    ///
    /// The value is the `sizeMultiplier` shipped for this gauge in `gauges.json`
    /// (`Resources/gauges.json` for the CLI, `App/Resources/gauges.json` for the
    /// App), so re-tuning a gauge is a config edit rather than a code change.
    /// Size — not presence — is what makes a coarse gauge read as coarse.
    var sizeMultiplier: Float { GaugeTunings.tuning(for: self).sizeMultiplier }

    /// Scales grain presence. Coarse gauges are louder, 75mm is nearly silent —
    /// that is where "almost grain-free" is delivered, by amplitude, not by
    /// pushing size into the aliased regime.
    var amplitudeMultiplier: Float { GaugeTunings.tuning(for: self).amplitudeMultiplier }

    /// Scales halation presence independently of grain and diffusion geometry.
    var halationMultiplier: Float { GaugeTunings.tuning(for: self).halationMultiplier }

    /// Short label for the gauge selector; the encoded value is the same short
    /// form, so exported metadata reads "35mm", not "thirtyFiveMillimetre".
    var displayName: String { rawValue }

    /// The lens-diffusion radius this gauge implies, derived from the format
    /// rather than chosen: see `DiffusionPhysics`, which scales a measured
    /// emulsion scatter radius by the enlargement each negative needs to fill
    /// the delivered frame. A smaller negative is enlarged more, so the same
    /// physical scatter lands wider — 8mm reads softest, 35mm sharpest, and the
    /// 75mm reference print is bypassed.
    var diffusionPreset: DiffusionPreset { DiffusionPhysics.preset(for: self) }

    /// This gauge's authored diffusion: its radius plus the amount shipped in
    /// `gauges.json`. A stock may override it; this is the gauge's own setting.
    var diffusion: DiffusionSettings { GaugeTunings.tuning(for: self).diffusion }

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

// MARK: - Gauge tuning configuration (gauges.json)

/// One print gauge's grain axes and its lens diffusion, as shipped in
/// `gauges.json`.
///
/// Diffusion lives here rather than on the stock because it is a property of the
/// format: the same stock printed at 16mm and at 75mm does not diffuse alike.
/// The preset is authored per gauge and validated against `PrintGauge`'s own
/// ladder, so the radius can never drift away from the format it belongs to.
struct GaugeTuning: Codable, Equatable, Sendable {
    let sizeMultiplier: Float
    let amplitudeMultiplier: Float
    let diffusionPreset: DiffusionPreset
    let diffusionAmount: Float
    var halationMultiplier: Float = 1

    var diffusion: DiffusionSettings {
        DiffusionSettings(preset: diffusionPreset, amount: diffusionAmount)
    }
}

/// The bundled gauge tuning document: exactly one entry per `PrintGauge`.
///
/// `gauges` is an array rather than a JSON object so a gauge listed twice is
/// visible to validation; a decoder would otherwise collapse duplicate object
/// keys and silently keep the last one.
struct GaugeTuningConfig: Codable, Equatable, Sendable {
    /// The only schema this renderer understands; anything else is rejected.
    static let currentSchemaVersion = 1
    static let resourceName = "gauges"
    static let resourceExtension = "json"

    struct Entry: Codable, Equatable, Sendable {
        let gauge: PrintGauge
        let sizeMultiplier: Float
        let amplitudeMultiplier: Float
        let diffusionPreset: DiffusionPreset
        let diffusionAmount: Float
        var halationMultiplier: Float? = nil
    }

    let schemaVersion: Int
    let gauges: [Entry]

    /// Validates the document and returns one tuning per gauge.
    ///
    /// Every defect throws — an unsupported schema, a duplicate entry, a gauge
    /// with no entry, or a multiplier that is not finite and positive. Nothing
    /// degrades to a plausible-looking default, so a typo in the shipped JSON
    /// fails the tests and the first render instead of quietly changing the look.
    func validated() throws -> [PrintGauge: GaugeTuning] {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GaugeConfigError.unsupportedSchemaVersion(schemaVersion)
        }
        var resolved: [PrintGauge: GaugeTuning] = [:]
        for entry in gauges {
            guard resolved[entry.gauge] == nil else {
                throw GaugeConfigError.duplicateGauge(entry.gauge.rawValue)
            }
            try Self.requirePositive(entry.sizeMultiplier, field: "sizeMultiplier", gauge: entry.gauge)
            try Self.requirePositive(entry.amplitudeMultiplier, field: "amplitudeMultiplier", gauge: entry.gauge)
            let halation = entry.halationMultiplier ?? 1
            guard halation.isFinite, (0...1).contains(halation) else {
                throw GaugeConfigError.invalidMultiplier(
                    gauge: entry.gauge.rawValue, field: "halationMultiplier", value: halation)
            }
            // The radius belongs to the format, so an entry whose preset does
            // not match its gauge is a defect, not a creative choice.
            guard entry.diffusionPreset == entry.gauge.diffusionPreset else {
                throw GaugeConfigError.mismatchedDiffusionPreset(
                    gauge: entry.gauge.rawValue, preset: entry.diffusionPreset.rawValue)
            }
            guard entry.diffusionAmount.isFinite, (0...1).contains(entry.diffusionAmount) else {
                throw GaugeConfigError.invalidDiffusionAmount(gauge: entry.gauge.rawValue,
                                                              value: entry.diffusionAmount)
            }
            resolved[entry.gauge] = GaugeTuning(sizeMultiplier: entry.sizeMultiplier,
                                                amplitudeMultiplier: entry.amplitudeMultiplier,
                                                diffusionPreset: entry.diffusionPreset,
                                                diffusionAmount: entry.diffusionAmount,
                                                halationMultiplier: halation)
        }
        let missing = PrintGauge.allCases.filter { resolved[$0] == nil }
        guard missing.isEmpty else {
            throw GaugeConfigError.missingGauges(missing.map(\.rawValue))
        }
        return resolved
    }

    private static func requirePositive(_ value: Float, field: String, gauge: PrintGauge) throws {
        guard value.isFinite, value > 0 else {
            throw GaugeConfigError.invalidMultiplier(gauge: gauge.rawValue, field: field, value: value)
        }
    }
}

enum GaugeConfigError: LocalizedError, Equatable {
    case missingResource(String)
    case unsupportedSchemaVersion(Int)
    case duplicateGauge(String)
    case missingGauges([String])
    case invalidMultiplier(gauge: String, field: String, value: Float)
    case mismatchedDiffusionPreset(gauge: String, preset: String)
    case invalidDiffusionAmount(gauge: String, value: Float)

    var errorDescription: String? {
        switch self {
        case .missingResource(let message):
            return message
        case .unsupportedSchemaVersion(let version):
            return "gauges.json schemaVersion \(version) is not supported."
        case .duplicateGauge(let gauge):
            return "gauges.json lists \(gauge) more than once."
        case .missingGauges(let gauges):
            return "gauges.json is missing entries for: \(gauges.joined(separator: ", "))."
        case .invalidMultiplier(let gauge, let field, let value):
            if field == "halationMultiplier" {
                return "gauges.json \(gauge).\(field) must be within 0...1, got \(value)."
            }
            return "gauges.json \(gauge).\(field) must be finite and positive, got \(value)."
        case .mismatchedDiffusionPreset(let gauge, let preset):
            return "gauges.json \(gauge) must use its own diffusion radius, got \(preset)."
        case .invalidDiffusionAmount(let gauge, let value):
            return "gauges.json \(gauge).diffusionAmount must be within 0...1, got \(value)."
        }
    }
}

/// Locates, decodes and validates `gauges.json`.
///
/// Both lookups are bundle-relative, so the App, the RenderCLI tool and the test
/// bundles resolve their copy without depending on the process working
/// directory — a CLI or test launched outside the checkout still loads it.
enum GaugeConfigLoader {
    /// Bundles that may carry the resource, most specific first.
    ///
    /// `Bundle(for:)` is the bundle the compiled code lives in: the App bundle,
    /// the tool's bundle, or the `.xctest` bundle a suite runs from.
    /// `Bundle.main` covers a tool whose resources are copied beside the
    /// executable instead.
    static func candidateBundles() -> [Bundle] {
        [Bundle(for: GaugeBundleToken.self), .main]
    }

    static func locate(in bundles: [Bundle] = candidateBundles()) -> URL? {
        for bundle in bundles {
            if let url = bundle.url(forResource: GaugeTuningConfig.resourceName,
                                    withExtension: GaugeTuningConfig.resourceExtension) {
                return url
            }
        }
        return nil
    }

    /// Decodes and validates a gauges document. Throws on any defect.
    static func decode(_ data: Data) throws -> [PrintGauge: GaugeTuning] {
        try JSONDecoder().decode(GaugeTuningConfig.self, from: data).validated()
    }

    static func load(contentsOf url: URL) throws -> [PrintGauge: GaugeTuning] {
        try decode(Data(contentsOf: url))
    }

    static func loadBundled(from bundles: [Bundle] = candidateBundles()) throws -> [PrintGauge: GaugeTuning] {
        guard let url = locate(in: bundles) else {
            throw GaugeConfigError.missingResource("gauges.json not found in bundle.")
        }
        return try load(contentsOf: url)
    }
}

/// The gauge tuning every renderer reads, resolved once per process from the
/// bundle that carries this code.
///
/// `gauges.json` is a shipped build input the grain tests validate, so a missing
/// or malformed copy is a packaging bug. It fails loudly here rather than
/// substituting a fallback ladder and shipping a different look.
enum GaugeTunings {
    static let resolved: [PrintGauge: GaugeTuning] = {
        do {
            return try GaugeConfigLoader.loadBundled()
        } catch {
            preconditionFailure("gauges.json is missing or invalid: \(error.localizedDescription)")
        }
    }()

    static func tuning(for gauge: PrintGauge) -> GaugeTuning {
        guard let tuning = resolved[gauge] else {
            preconditionFailure("gauges.json has no entry for \(gauge.rawValue)")
        }
        return tuning
    }
}

private final class GaugeBundleToken {}

/// Pure grain math shared by the Metal kernel and the CPU-side uniforms so the
/// gauge's two axes stay unit-testable without a GPU.
enum GrainModel {
    /// Single loudness scale: presence is `baseAmount · gaugeAmplitude`. There is
    /// no ISO term — ISO is exposure only.
    static let baseAmount: Float = 0.55
    /// Below footprint ~1.0 the 128-cubed volume is undersampled: lag-1
    /// correlation collapses and finer size yields aliased noise, not finer
    /// grain. Floor the effective size so the axis cannot reach that regime.
    ///
    /// The bound is unchanged by gauge tuning, and that is why the finest gauge
    /// cannot reach exactly half its previous footprint on the shipped stocks:
    /// 75mm asks for 0.5 × stock size (0.575 and 0.65), both under the floor, so
    /// the delivered footprint stops at 0.95.
    static let footprintFloor: Float = 0.95
    /// Ceiling for the coarse end. Raised alongside the 8mm multiplier so the
    /// coarse gauge is not silently clipped back to a small footprint.
    static let footprintCeiling: Float = 16.0

    /// The frame every gauge's footprint was authored against: one 128^3 volume
    /// texel is one grain cell, and a cell spans `footprint` pixels of THIS
    /// frame. A 4K delivery render is the reference, and it is the same number
    /// the stock preview converts its drawable against.
    static let referenceLongEdge: Float = 3840

    /// Reference pixels per raster pixel for a pass writing `width` x `height`.
    ///
    /// 1 at the reference raster, below 1 on a wider frame and above 1 on a
    /// smaller one. Dividing the footprint by it keeps one cell the same size
    /// relative to the picture at any raster, which is what a digitally cropped
    /// still (raster = source / crop) and a 4:3 delivery crop (2880 of 3840)
    /// both need. An empty or non-finite raster resolves to the reference, so a
    /// caller that cannot state its raster leaves the cell unchanged rather
    /// than scaling it by a nonsense factor.
    static func referenceScale(width: Int, height: Int) -> Float {
        let longEdge = Float(max(width, height))
        guard longEdge.isFinite, longEdge > 0 else { return 1 }
        return referenceLongEdge / longEdge
    }

    /// Photo-only presence. A native-crop A/B on a real 1000 ISO DNG at equal
    /// stock/seed/gauge reduced residual RMS from 0.00957 (gain 2) to 0.00478
    /// (gain 1.5) with texture still visible; 35 mm read as too rough before.
    /// Video amplitude is touched by this constant.
    static let stillPresenceGain: Float = 1.5

    /// Dye-cloud chroma strength as a fraction of the shared luminance grain.
    ///
    /// Film grain is overwhelmingly a *density* fluctuation: the three emulsion
    /// layers move together and the result reads as monochrome. The colour layers
    /// add only a small decorrelated component. Video can carry the full amount
    /// because the eye integrates several frames of a re-randomised field, but a
    /// single still inspected at 1:1 shows the anti-correlated red/blue term as
    /// coloured specks — red, green and blue pixels — which no real emulsion
    /// produces. Stills therefore use `stillChromaAmount`.
    static let videoChromaAmount: Float = 0.12
    static let stillChromaAmount: Float = 0.02

    /// Effective footprint: stock size x gauge size, clamped off the sampling
    /// floor. At 75mm on a 1.3 stock this is 1.3 x 0.5 = 0.65 -> floored to
    /// 0.95. The remaining graininess at 75mm is reduced by the 0.165 amplitude
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
