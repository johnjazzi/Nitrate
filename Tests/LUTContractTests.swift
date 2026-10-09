import Foundation
import Testing

/// Verifies the "Apple Log 2 → Rec.709" stock LUTs are structurally sound for
/// story 1.3's "tolerant golden" acceptance: the neutral axis (R == G == B input)
/// must stay monotonic, reach a lifted-but-not-clipped black point, roll off to
/// near-white without hard-clipping, and never introduce a wild per-channel cast.
///
/// These are structural invariants, NOT a colorimetric claim — the input gamut
/// stays "unverified" in the recipe (see `RenderRecipe.colorContractVerified`).
struct LUTContractTests {
    // Tolerant bounds derived from the shipped Resolve .cube set (33³, all 10 LUTs).
    private let blackFloorRange: ClosedRange<Float> = 0.01...0.06
    private let whitePointRange: ClosedRange<Float> = 0.90...1.0
    private let maxNeutralCast: Float = 0.15   // measured max ≈ 0.126 (F3513DI prints)

    @Test func allStockLUTsTrackNeutralAxisWithoutClipping() throws {
        let stocks = try loadStocks()
        #expect(stocks.count == 10)
        for config in stocks {
            let (_, values) = try parseCubeLUT(config.lutName)
            let axis = neutralAxis(values: values)
            checkNeutralAxis(axis, stockID: config.stockId)
        }
    }

    @Test func lutCountsMatchStockGridSize() throws {
        // The renderer uploads the full 33³ grid; a truncated .cube would throw
        // before this, but pin the expected size so a repackaged LUT is noticed.
        let stocks = try loadStocks()
        for config in stocks {
            let (size, values) = try parseCubeLUT(config.lutName)
            #expect(size == 33)
            #expect(values.count == size * size * size * 4)
        }
    }

    // MARK: - Helpers

    private func checkNeutralAxis(_ axis: [(Float, Float, Float)], stockID: String) {
        // Rec.709 luma, matching pipeline.metal's `dot(color.rgb, float3(0.2126, 0.7152, 0.0722))`.
        func luma(_ rgb: (Float, Float, Float)) -> Float {
            0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        }

        var previous: Float?
        var monotonic = true
        var minChannel = Float.greatestFiniteMagnitude
        var maxChannel = -Float.greatestFiniteMagnitude
        var maxCast: Float = 0
        var topGradientSteps = 0

        let lumas = axis.map(luma)
        for (index, rgb) in axis.enumerated() {
            let lumaValue = lumas[index]
            if let prev = previous, lumaValue < prev - 1e-6 { monotonic = false }
            previous = lumaValue
            minChannel = min(minChannel, min(rgb.0, min(rgb.1, rgb.2)))
            maxChannel = max(maxChannel, max(rgb.0, max(rgb.1, rgb.2)))
            maxCast = max(maxCast, max(abs(rgb.0 - rgb.1), max(abs(rgb.1 - rgb.2), abs(rgb.0 - rgb.2))))
        }
        // How many of the top 4 neutral steps reach ~white (would read as a hard clip).
        topGradientSteps = lumas.suffix(4).filter { $0 >= 0.99 }.count

        // 1. No tonal inversions (monotonic non-decreasing).
        #expect(monotonic, "\(stockID): neutral axis is not monotonic")
        // 2. No out-of-range values that would clip at the bgra8 write (allow float epsilon).
        #expect(minChannel >= -0.001 && maxChannel <= 1.001, "\(stockID): neutral axis leaves [0,1]: min \(minChannel) max \(maxChannel)")
        // 3. Film lifts the black point (no crush to 0).
        #expect(blackFloorRange.contains(lumas.first ?? 0), "\(stockID): black point \(lumas.first ?? 0) outside \(blackFloorRange)")
        // 4. Highlights roll off to near-white without hard-clipping to 1.0.
        #expect(whitePointRange.contains(lumas.last ?? 0), "\(stockID): white point \(lumas.last ?? 0) outside \(whitePointRange)")
        // 5. Neutral axis keeps a bounded (film-consistent) per-channel cast.
        #expect(maxCast < maxNeutralCast, "\(stockID): neutral cast \(maxCast) exceeds \(maxNeutralCast)")
        // 6. No highlight plateau: at most 2 of the top 4 steps may sit at ~white.
        #expect(topGradientSteps <= 2, "\(stockID): highlight plateau (\(topGradientSteps) of top 4 steps ≥ 0.99)")
    }

    /// Neutral-axis grid points: input (t, t, t) for t in 0..size. Grid index for
    /// a red-fastest Resolve cube is `r + g*size + b*size*size`, so the neutral
    /// axis sits at `i + i*size + i*size*size`.
    private func neutralAxis(values: [Float]) -> [(Float, Float, Float)] {
        let size = Int(round(cbrt(Double(values.count / 4))))
        return (0..<size).map { index in
            let idx = (index + index * size + index * size * size) * 4
            return (values[idx], values[idx + 1], values[idx + 2])
        }
    }

    /// Minimal .cube parser mirroring PipelineRenderer.parseCubeLUT (RGB triplets,
    /// red fastest, alpha appended). Returns (size, rgba values).
    private func parseCubeLUT(_ lutName: String) throws -> (Int, [Float]) {
        let url = root.appendingPathComponent("Resources/LUTs").appendingPathComponent(lutName)
        let content = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []
        var headerParsed = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size = Int(trimmed.split(separator: " ")[1]) ?? 0
                headerParsed = true
                continue
            }
            if headerParsed, upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") { continue }
            if headerParsed {
                let nums = trimmed.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                if nums.count == 3 { values.append(contentsOf: nums + [1.0]) }
            }
        }
        let expected = size * size * size * 4
        #expect(size > 0 && values.count == expected, "\(lutName): parsed \(values.count/4) triplets, expected \(size)³")
        return (size, values)
    }

    struct Container: Decodable { let stocks: [FilmStockConfig] }

    private func loadStocks() throws -> [FilmStockConfig] {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/stocks.json"))
        return try JSONDecoder().decode(Container.self, from: data).stocks
    }

    /// Repo root: this file lives at Tests/LUTContractTests.swift.
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
