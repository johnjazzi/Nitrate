import Foundation
import AVFoundation
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
    var outputContrast: Float = 1.0
    /// Fixed white-balance color temperature (Kelvin) for this stock.
    /// Daylight stocks use 5600K; tungsten stocks use 3200K. The camera locks
    /// white balance to this so the Apple Log → LUT transform sees a consistent
    /// per-stock white point. Defaults to daylight when the key is absent.
    var colorTemperature: Float = 5600
    var defaultISO: Float
    var recipe: RenderRecipe? = nil

    /// Copy the complete value so per-shot ISO cannot discard recipe or display metadata.
    func overridingISO(_ iso: Float) -> FilmStockConfig {
        var copy = self
        copy.defaultISO = iso
        return copy
    }

    func validate() throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw RenderContractError.invalid(stockID: stockId, field: field) }
        }
        try require(!lutName.isEmpty, "lutName")
        try require(halationStrength.isFinite && (0...1).contains(halationStrength), "halationStrength")
        try require(glowStrength.isFinite && (0...1).contains(glowStrength), "glowStrength")
        try require(grainSize.isFinite && grainSize > 0, "grainSize")
        try require(outputContrast.isFinite && (0.1...2).contains(outputContrast), "outputContrast")
        try require(colorTemperature.isFinite && (2000...10000).contains(colorTemperature), "colorTemperature")
        try require(defaultISO.isFinite && defaultISO > 0 && Double(defaultISO) < Double(Int.max), "ISO")
        try effectiveRecipe.validate(stockID: stockId)
    }

    /// Legacy configurations remain explicitly unverified rather than acquiring a color claim.
    var effectiveRecipe: RenderRecipe { recipe ?? .unverified }

    /// Primary tint hex for duotone display (e.g. "#E8C46C"). Optional; defaults to grey.
    var primaryTint: String?
    /// Secondary tint hex for duotone display. Optional; defaults to a darker shade.
    var secondaryTint: String?

    /// Daylight (D) or Tungsten (T) based on display name.
    var lightType: String {
        let uppercased = displayName.uppercased()
        if uppercased.contains("T") && !uppercased.contains("DI") { return "T" }
        return "D"
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
    var deliveryAlgorithm: String

    static let unverified = RenderRecipe(schemaVersion: 1, version: "legacy-unversioned",
        input: .init(gamut: "unverified", transfer: "unverified", provenance: "unverified"),
        output: .init(gamut: "unverified", transfer: "unverified", provenance: "unverified"),
        domainMin: [0, 0, 0], domainMax: [1, 1, 1], domainProvenance: "implicit-cube-default",
        lutAlgorithm: "resolve-rgb-red-fastest-linear-clamp-v1",
        halationAlgorithm: "input-luma-warm-highlight-addition-v1",
        glowAlgorithm: "constant-warm-addition-v1",
        grainAlgorithm: "hashed-128-volume-iso-subtractive-dither-v1",
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
            ("grainAlgorithm", grainAlgorithm, Self.unverified.grainAlgorithm),
            ("deliveryAlgorithm", deliveryAlgorithm, Self.unverified.deliveryAlgorithm)
        ] { try require(actual == expected, name) }
        try require(domainMin == [0, 0, 0] && domainMax == [1, 1, 1], "unsupported sampling domain")
    }
}

enum RenderEncodingContract {
    static let averageBitRate = 60_000_000
    static let codec = "hvc1"
    /// Color-managed chain: the reader passes the source through WITHOUT an
    /// AVFoundation colorspace conversion, so the shader sees the source's
    /// Apple Log 2 code values (input gamut still "unverified"); the per-stock
    /// LUT maps Apple Log 2 → Rec.709 SDR; these constants tag that Rec.709
    /// output on the writer. Matches the LUT pack's declared input/output.
    static let colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    static let transferFunction = AVVideoTransferFunction_ITU_R_709_2
    static let yCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
}

/// App-side configurable delivery parameters, backed by UserDefaults so a future
/// settings UI can change them without touching the render pipeline. RenderCLI
/// overrides the bitrate via `--bitrate` instead of this store.
enum DeliverySettings {
    static let defaultAverageBitRate = 60_000_000
    private static let bitrateKey = "delivery.averageBitRate"

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
