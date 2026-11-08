import Foundation
import AVFoundation
import simd
#if canImport(SwiftUI)
import SwiftUI
#endif

/// AD-10: Value-type contract for film stock configuration.
/// Never constructed directly — always via FilmStockLibrary.
struct FilmStockConfig: Codable, Equatable, Sendable {
    let stockId: String
    let displayName: String
    let category: StockCategory
    let lutName: String
    let halationStrength: Float
    let glowStrength: Float
    let grainSize: Float
    /// Per-stock halation geometry and red-dominant layer weights. Radius is an
    /// authored fraction of the half-resolution frame width, not a measured
    /// emulsion thickness; different stocks may share a tuned starting radius.
    /// Red stays full-scale so overall gain belongs to `halationStrength`, not
    /// to a dim tint. Defaults preserve legacy JSON that omits these keys.
    var halationRadiusFraction: Float = 0.012
    var halationTint: SIMD3<Float> = SIMD3(1.0, 0.32, 0.10)
    var outputContrast: Float = 1.0
    /// Fixed white-balance color temperature (Kelvin) for this stock.
    /// Daylight stocks use 5600K; tungsten stocks use 3200K. The camera locks
    /// white balance to this so the Apple Log → LUT transform sees a consistent
    /// per-stock white point. Defaults to daylight when the key is absent.
    var colorTemperature: Float = 5600
    var defaultISO: Float
    var recipe: RenderRecipe? = nil
    /// Print gauge owning grain size and amplitude (m00459/m00581). Optional so
    /// a stocks.json without the key decodes to the neutral 35mm reference.
    var printGauge: PrintGauge? = nil
    /// Lens diffusion node for this stock. Optional so a stocks.json without the
    /// key decodes to a disabled node: the node ships off until a stock authors
    /// a preset and an amount.
    var diffusion: DiffusionSettings? = nil
    /// Render-time push/pull in fixed stops, applied to the Apple Log 2 code
    /// before the stock's cube. Defaults to neutral so stocks.json and every
    /// queue written before the control existed keep rendering unchanged.
    var pushPull: PushPullExposure? = nil
    /// How much of `halationStrength` the STILL render applies.
    ///
    /// A developed photo and a recorded take are measured in the same scene
    /// light, but they do not read alike: a take's halo is masked by motion and
    /// a 24th-of-a-second of it is spent on each frame, while a still is held in
    /// front of the viewer with the halo at full size next to unrelated detail.
    /// Measured on a ProRAW the two are numerically equivalent and the still
    /// still reads hot, so a still gets a smaller share of the same physical
    /// model rather than a second, separate model.
    ///
    /// Optional, and resolved to 1 when absent: synthesized `Codable` requires a
    /// key for every non-optional property, and every other optional knob in this
    /// struct exists for exactly that reason — a stocks.json written before the
    /// key existed must still decode and still render the take's strength.
    var stillHalationScale: Float? = nil

    /// The still share actually applied to a photo render.
    var effectiveStillHalationScale: Float { stillHalationScale ?? 1 }

    /// How much of the diffusion amount a STILL render applies. Same reasoning as
    /// `stillHalationScale`, and deliberately the same lever: a take spends a
    /// 24th of a second with the softness next to motion, while a still is held
    /// in front of the viewer with nothing to compare it to. The RADIUS is left
    /// alone — it is the physical spread — so the halo keeps its geometry and
    /// only the mix changes.
    ///
    /// Optional and resolved to 1 when absent, for the same reason as above.
    var stillDiffusionScale: Float? = nil

    var effectiveStillDiffusionScale: Float { stillDiffusionScale ?? 1 }

    /// The diffusion node a still render actually applies.
    var effectiveStillDiffusion: DiffusionSettings {
        let authored = effectiveDiffusion
        let scale = effectiveStillDiffusionScale
        guard authored.isEnabled, scale < 1 else { return authored }
        return DiffusionSettings(preset: authored.preset,
                                 amount: max(0, min(1, authored.amount * scale)))
    }

    /// Stock halation gain after the selected format's authored presence.
    func halationStrength(for gauge: PrintGauge) -> Float {
        halationStrength * gauge.halationMultiplier
    }

    var effectiveHalationStrength: Float { halationStrength(for: effectivePrintGauge) }

    /// The gauge actually applied to the render: the selected gauge or 35mm.
    var effectivePrintGauge: PrintGauge { printGauge ?? .neutral }

    /// The diffusion actually applied to the render.
    ///
    /// A stock may author its own settings; otherwise the PRINT GAUGE owns them,
    /// because diffusion is a property of the format rather than of the emulsion
    /// — the same stock printed at 16mm and at 75mm does not diffuse alike.
    var effectiveDiffusion: DiffusionSettings { diffusion ?? effectivePrintGauge.diffusion }

    /// The push/pull actually applied to the render: the chosen setting, or
    /// neutral when the document/queue predates the control.
    var effectivePushPull: PushPullExposure { pushPull ?? .neutral }

    /// Copy the complete value so per-shot ISO cannot discard recipe or display metadata.
    func overridingISO(_ iso: Float) -> FilmStockConfig {
        var copy = self
        copy.defaultISO = iso
        return copy
    }

    /// Copy with an explicit diffusion override, so one render can be compared
    /// against the same stock and gauge with the node off. Mirrors the other
    /// `overriding*` copies: it never discards the recipe or display metadata.
    func overridingDiffusion(_ diffusion: DiffusionSettings?) -> FilmStockConfig {
        var copy = self
        copy.diffusion = diffusion
        return copy
    }

    /// Copy with a print-gauge override, so a per-shot gauge cannot discard the
    /// recipe or display metadata (mirrors `overridingISO`).
    func overridingGauge(_ gauge: PrintGauge?) -> FilmStockConfig {
        var copy = self
        copy.printGauge = gauge
        return copy
    }

    /// Copy with a per-shot push/pull, so the stop count cannot discard the
    /// recipe or display metadata (mirrors `overridingISO` / `overridingGauge`).
    func overridingPushPull(_ pushPull: PushPullExposure) -> FilmStockConfig {
        var copy = self
        copy.pushPull = pushPull
        return copy
    }

    func validate() throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw RenderContractError.invalid(stockID: stockId, field: field) }
        }
        try require(!lutName.isEmpty, "lutName")
        try require(halationStrength.isFinite && (0...8).contains(halationStrength), "halationStrength")
        try require(glowStrength.isFinite && (0...1).contains(glowStrength), "glowStrength")
        try require(grainSize.isFinite && grainSize > 0, "grainSize")
        if let stillHalationScale {
            try require(stillHalationScale.isFinite && (0...1).contains(stillHalationScale),
                        "stillHalationScale")
        }
        if let stillDiffusionScale {
            try require(stillDiffusionScale.isFinite && (0...1).contains(stillDiffusionScale),
                        "stillDiffusionScale")
        }
        try require(halationRadiusFraction.isFinite && halationRadiusFraction > 0
            && halationRadiusFraction <= 0.5, "halationRadiusFraction")
        // Full-scale red is the documented contract (see the field comment): a
        // dim red would make the halo weaker than the stock's strength dial
        // intends. Green and blue may sit anywhere in the published range.
        try require(halationTint.x == 1.0 && halationTint.y.isFinite && halationTint.z.isFinite
            && (0...1).contains(halationTint.y) && (0...1).contains(halationTint.z), "halationTint")
        try require(outputContrast.isFinite && (0.1...2).contains(outputContrast), "outputContrast")
        try require(colorTemperature.isFinite && (2000...10000).contains(colorTemperature), "colorTemperature")
        try require(defaultISO.isFinite && defaultISO > 0 && Double(defaultISO) < Double(Int.max), "ISO")
        // A bypassed preset is always allowed; a live one must stay in 0...1 so
        // the scene-linear blend can never invert or over-gain the frame.
        try require(effectiveDiffusion.amount.isFinite && (0...1).contains(effectiveDiffusion.amount),
                    "diffusion.amount")
        try require(effectivePushPull.meteredOffsetEV?.isFinite ?? true, "pushPull.meteredOffsetEV")
        try require(PushPullStops.allCases.contains(effectivePushPull.stops), "pushPull.stops")
        try effectiveRecipe.validate(stockID: stockId)
    }

    /// Legacy configurations remain explicitly unverified rather than acquiring a color claim.
    var effectiveRecipe: RenderRecipe { recipe ?? .unverified }

    /// Primary tint hex for duotone display (e.g. "#E8C46C"). Optional; defaults to grey.
    var primaryTint: String?
    /// Secondary tint hex for duotone display. Optional; defaults to a darker shade.
    var secondaryTint: String?

    /// Daylight (D) or Tungsten (T).
    ///
    /// Derived from the stock's white-balance temperature — the actual
    /// discriminator, 5600 K daylight versus 3200 K tungsten — rather than
    /// parsed out of the display name, which tagged any name containing a "T"
    /// as tungsten.
    var lightType: String {
        colorTemperature > 4500 ? "D" : "T"
    }

#if canImport(SwiftUI)
    var primaryColor: Color {
        if let hex = primaryTint { return Color(hex: hex) }
        return .gray
    }

    var secondaryColor: Color {
        if let hex = secondaryTint { return Color(hex: hex) }
        return primaryColor.opacity(0.5)
    }
#endif

    enum StockCategory: String, Codable, Equatable {
        case video
        case photo
    }
}

// MARK: - Color Hex Helper

#if canImport(SwiftUI)
private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
#endif

/// Versioned description of the existing operations; it does not introduce color conversions.
struct RenderRecipe: Codable, Equatable, Sendable {
    struct ColorInterpretation: Codable, Equatable, Sendable {
        var gamut: String
        var transfer: String
        var provenance: String
    }
    var schemaVersion: Int
    var version: String
    var input: ColorInterpretation
    var output: ColorInterpretation
    var domainMin: [Float]
    var domainMax: [Float]
    var domainProvenance: String
    var lutAlgorithm: String
    var halationAlgorithm: String
    var glowAlgorithm: String
    var grainAlgorithm: String
    /// Edge-only amplitude multiplier. Legacy v2 archives decode to zero.
    var edgeBoostMultiplier: Float = 0
    var deliveryAlgorithm: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, input, output, domainMin, domainMax, domainProvenance
        case lutAlgorithm, halationAlgorithm, glowAlgorithm, grainAlgorithm
        case edgeBoostMultiplier, deliveryAlgorithm
    }

    static let legacyGrainAlgorithm = "coherent-multiscale-mean-preserving-softness-v2"
    static let edgeAmplitudeAlgorithm = "coherent-multiscale-edge-amplitude-v3"

    static let unverified = RenderRecipe(schemaVersion: 1, version: "legacy-unversioned",
        input: .init(gamut: "unverified", transfer: "unverified", provenance: "unverified"),
        output: .init(gamut: "unverified", transfer: "unverified", provenance: "unverified"),
        domainMin: [0, 0, 0], domainMax: [1, 1, 1], domainProvenance: "implicit-cube-default",
        lutAlgorithm: "resolve-rgb-red-fastest-texel-center-linear-clamp-v2",
        halationAlgorithm: "scene-linear-pre-lut-layer-diffusion-v3",
        glowAlgorithm: "blurred-warm-highlight-addition-v2",
        grainAlgorithm: legacyGrainAlgorithm,
        edgeBoostMultiplier: 0,
        deliveryAlgorithm: "clamp-bgra8-hevc-rec709-tagged-v1")

    var colorContractVerified: Bool {
        input.provenance == "verified" && output.provenance == "verified"
            && input.gamut != "unverified" && input.transfer != "unverified"
            && output.gamut != "unverified" && output.transfer != "unverified"
            && domainProvenance == "verified"
    }

    func validate(stockID: String) throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw RenderContractError.invalid(stockID: stockID, field: "recipe.\(field)") }
        }
        try require(schemaVersion == 1, "schemaVersion")
        try require(!version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "version")
        for (name, color) in [("input", input), ("output", output)] {
            try require(!color.gamut.isEmpty && !color.transfer.isEmpty, name)
            try require(["unverified", "user-declared", "verified"].contains(color.provenance), "\(name).provenance")
        }
        try require(["unverified", "implicit-cube-default", "verified"].contains(domainProvenance), "domainProvenance")
        try require(domainMin.count == 3 && domainMax.count == 3, "domain")
        try require(zip(domainMin, domainMax).allSatisfy { $0.isFinite && $1.isFinite && $0 < $1 }, "domain")
        // These are the only algorithms this renderer implements.
        for (name, actual, expected) in [
            ("lutAlgorithm", lutAlgorithm, Self.unverified.lutAlgorithm),
            ("halationAlgorithm", halationAlgorithm, Self.unverified.halationAlgorithm),
            ("glowAlgorithm", glowAlgorithm, Self.unverified.glowAlgorithm),
            ("deliveryAlgorithm", deliveryAlgorithm, Self.unverified.deliveryAlgorithm)
        ] { try require(actual == expected, name) }
        try require(
            grainAlgorithm == Self.legacyGrainAlgorithm || grainAlgorithm == Self.edgeAmplitudeAlgorithm,
            "grainAlgorithm"
        )
        try require(edgeBoostMultiplier.isFinite && (0...3).contains(edgeBoostMultiplier), "edgeBoostMultiplier")
        try require(grainAlgorithm != Self.legacyGrainAlgorithm || edgeBoostMultiplier == 0, "edgeBoostMultiplier")
        try require(domainMin == [0, 0, 0] && domainMax == [1, 1, 1], "unsupported sampling domain")
    }
}

extension RenderRecipe {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        version = try values.decode(String.self, forKey: .version)
        input = try values.decode(ColorInterpretation.self, forKey: .input)
        output = try values.decode(ColorInterpretation.self, forKey: .output)
        domainMin = try values.decode([Float].self, forKey: .domainMin)
        domainMax = try values.decode([Float].self, forKey: .domainMax)
        domainProvenance = try values.decode(String.self, forKey: .domainProvenance)
        lutAlgorithm = try values.decode(String.self, forKey: .lutAlgorithm)
        halationAlgorithm = try values.decode(String.self, forKey: .halationAlgorithm)
        glowAlgorithm = try values.decode(String.self, forKey: .glowAlgorithm)
        grainAlgorithm = try values.decode(String.self, forKey: .grainAlgorithm)
        edgeBoostMultiplier = try values.decodeIfPresent(Float.self, forKey: .edgeBoostMultiplier)
            ?? (grainAlgorithm == Self.edgeAmplitudeAlgorithm ? 3 : 0)
        deliveryAlgorithm = try values.decode(String.self, forKey: .deliveryAlgorithm)
    }
}

enum RenderEncodingContract {
    static let averageBitRate = 60_000_000
    static let codec = "hvc1"
    /// The renderer requires stream tags declaring Apple Log 2 and requests
    /// wide-color RGBAHalf decoding. These constants tag the declared Rec.709
    /// delivery; they do not verify decoded values or the LUT's input/output
    /// calibration. The effective recipe preserves its provenance separately.
    static let colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    static let transferFunction = AVVideoTransferFunction_ITU_R_709_2
    static let yCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
}

/// Rendered-video bitrate policy only; original capture and RenderCLI remain independent.
enum RenderExportQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case smaller

    var id: String { rawValue }

    var averageBitRate: Int {
        switch self {
        case .high: return 60_000_000
        case .smaller: return 30_000_000
        }
    }

    var title: String {
        switch self {
        case .high: return "High"
        case .smaller: return "Smaller"
        }
    }
}

/// Value snapshot of export preferences, suitable for persisting with a queued render.
struct RenderDeliveryPreferences: Codable, Equatable, Sendable {
    /// Video switch: deliver the ungraded original recording alongside the render.
    var saveOriginalLog: Bool
    /// Photo switch, independent of `saveOriginalLog`: deliver the captured DNG
    /// as a second Photos resource next to the developed JPEG.
    var saveOriginalRAWToPhotos: Bool
    var quality: RenderExportQuality
    /// Delivery framing chosen when the item was enqueued. Captured in the
    /// snapshot for the same reason quality is: a render reads the job's own
    /// record, never live Settings, so changing the row cannot re-crop work
    /// that is already waiting in the queue.
    var framing: DeliveryFraming

    init(saveOriginalLog: Bool = false, saveOriginalRAWToPhotos: Bool = false,
         quality: RenderExportQuality = .high,
         framing: DeliveryFraming = DeliveryFraming.defaultValue) {
        self.saveOriginalLog = saveOriginalLog
        self.saveOriginalRAWToPhotos = saveOriginalRAWToPhotos
        self.quality = quality
        self.framing = framing
    }

    private enum CodingKeys: String, CodingKey {
        case saveOriginalLog, saveOriginalRAWToPhotos, quality, framing
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        saveOriginalLog = try values.decodeIfPresent(Bool.self, forKey: .saveOriginalLog) ?? false
        // Queues written before the photo switch existed deliver JPEG only.
        saveOriginalRAWToPhotos = try values.decodeIfPresent(Bool.self, forKey: .saveOriginalRAWToPhotos) ?? false
        // Newer queues may carry a quality this version does not recognize.
        let rawQuality = try? values.decodeIfPresent(String.self, forKey: .quality)
        quality = rawQuality.flatMap(RenderExportQuality.init(rawValue:)) ?? .high
        // Queues written before framing existed deliver the full 16:9 frame.
        let rawFraming = try? values.decodeIfPresent(String.self, forKey: .framing)
        framing = DeliveryFraming.resolved(rawFraming ?? nil)
    }
}

/// App-side preferences. The legacy bitrate store also controls original capture
/// and storage estimates; render quality must not change it. RenderCLI overrides
/// bitrate via `--bitrate` independently of these export preferences.
enum DeliverySettings {
    static let defaultAverageBitRate = 60_000_000
    /// AAC bitrate for the recorded original's audio track.
    static let aacAverageBitRate = 192_000
    private static let bitrateKey = "delivery.averageBitRate"
    static let saveOriginalLogKey = "delivery.saveOriginalLog"
    /// Photo-only switch; independent of the video original switch above.
    static let saveOriginalRAWToPhotosKey = "delivery.saveOriginalRAWToPhotos"
    static let renderQualityKey = "delivery.renderQuality"
    /// Shared with the Settings row and the delivered file's metadata value.
    static let deliveryFramingKey = DeliveryFraming.preferenceKey

    static func renderPreferences(defaults: UserDefaults = .standard) -> RenderDeliveryPreferences {
        let quality = defaults.string(forKey: renderQualityKey)
            .flatMap(RenderExportQuality.init(rawValue:)) ?? .high
        return RenderDeliveryPreferences(
            saveOriginalLog: defaults.bool(forKey: saveOriginalLogKey),
            saveOriginalRAWToPhotos: defaults.bool(forKey: saveOriginalRAWToPhotosKey),
            quality: quality,
            framing: DeliveryFraming.resolved(defaults.string(forKey: deliveryFramingKey))
        )
    }

    static var averageBitRate: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: bitrateKey)
            return stored > 0 ? stored : defaultAverageBitRate
        }
        set { UserDefaults.standard.set(newValue, forKey: bitrateKey) }
    }
}

enum RenderContractError: LocalizedError {
    case invalid(stockID: String, field: String)
    var errorDescription: String? {
        switch self {
        case .invalid(let stockID, let field): return "Invalid render configuration for \(stockID): \(field)."
        }
    }
}
