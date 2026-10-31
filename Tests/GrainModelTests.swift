import Foundation
import Testing

/// Pure-math cover for the grain model and its bundled `gauges.json`: the print
/// gauge owns grain size AND presence (amplitude); ISO is the exposure index and
/// does not scale grain. These run without a Metal GPU; the GPU-level checks live
/// in `GrainShadowTests`.
struct GrainModelTests {
    private let tolerance: Float = 0.0001

    /// Tuning shipped in `gauges.json`: the previous ladder (4.0 / 2.7 / 1.8 /
    /// 1.0) halved on the size axis, and 10% above the previous presence.
    private static let shippedSizes: [PrintGauge: Float] = [
        .eightMillimetre: 2.0, .sixteenMillimetre: 1.35,
        .thirtyFiveMillimetre: 0.9, .seventyFiveMillimetre: 0.5
    ]
    private static let shippedAmplitudes: [PrintGauge: Float] = [
        .eightMillimetre: 0.55, .sixteenMillimetre: 0.396,
        .thirtyFiveMillimetre: 0.36, .seventyFiveMillimetre: 0.165
    ]
    /// Presence lift over the previous ladder, per gauge. 35mm carries more than
    /// the 10% the other gauges ship: at half its previous footprint, card-size
    /// grain measured 0.003386 against one 8-bit display step of 0.003922, and
    /// 0.36 is the presence that clears that floor (measured 0.004033).
    private static let presenceLift: [PrintGauge: Float] = [
        .eightMillimetre: 1.1, .sixteenMillimetre: 1.1,
        .thirtyFiveMillimetre: 4.0 / 3.0, .seventyFiveMillimetre: 1.1
    ]
    /// The ladder this tuning replaced, used to state the half-size contract.
    private static let previousSizes: [PrintGauge: Float] = [
        .eightMillimetre: 4.0, .sixteenMillimetre: 2.7,
        .thirtyFiveMillimetre: 1.8, .seventyFiveMillimetre: 1.0
    ]
    private static let previousAmplitudes: [PrintGauge: Float] = [
        .eightMillimetre: 0.50, .sixteenMillimetre: 0.36,
        .thirtyFiveMillimetre: 0.27, .seventyFiveMillimetre: 0.15
    ]
    /// `grainSize` of the two shipped stocks in `stocks.json`.
    private static let shippedStockSizes: [Float] = [1.15, 1.3]

    // MARK: - Bundled configuration

    /// The shipped JSON is the single source of the ladder, both copies are
    /// byte-identical, and it loads from the bundle without a source checkout.
    @Test func bundledGaugeConfigIsTheTuningSourceOfTruth() throws {
        let cli = try Data(contentsOf: TestRepository.url(for: "Resources/gauges.json"))
        let app = try Data(contentsOf: TestRepository.url(for: "App/Resources/gauges.json"))
        #expect(cli == app, "the CLI and App copies of gauges.json must be byte-identical")

        // The typed document, before validation.
        let document = try JSONDecoder().decode(GaugeTuningConfig.self, from: cli)
        #expect(document.schemaVersion == GaugeTuningConfig.currentSchemaVersion)
        #expect(document.gauges.count == PrintGauge.allCases.count)

        let resolved = try GaugeConfigLoader.decode(cli)
        #expect(Set(resolved.keys) == Set(PrintGauge.allCases), "every gauge must be tuned")

        // The same document resolved from the bundle carrying this code, which is
        // what the App and the CLI read at launch regardless of the cwd.
        let bundled = try GaugeConfigLoader.loadBundled()
        #expect(bundled == resolved)

        for gauge in PrintGauge.allCases {
            let tuning = try #require(resolved[gauge])
            let size = try #require(Self.shippedSizes[gauge])
            let amplitude = try #require(Self.shippedAmplitudes[gauge])
            #expect(abs(tuning.sizeMultiplier - size) < tolerance,
                    "\(gauge.rawValue) size: \(tuning.sizeMultiplier)")
            #expect(abs(tuning.amplitudeMultiplier - amplitude) < tolerance,
                    "\(gauge.rawValue) amplitude: \(tuning.amplitudeMultiplier)")
            // The enum properties delegate to the config rather than holding a copy.
            #expect(gauge.sizeMultiplier == tuning.sizeMultiplier)
            #expect(gauge.amplitudeMultiplier == tuning.amplitudeMultiplier)
        }
    }

    /// Malformed documents fail closed: no missing or duplicated gauge, no
    /// non-finite or non-positive multiplier, no unknown schema or gauge id.
    @Test func gaugeConfigRejectsIncompleteAndInvalidDocuments() throws {
        func decode(_ json: String) throws -> [PrintGauge: GaugeTuning] {
            try GaugeConfigLoader.decode(Data(json.utf8))
        }
        let shipped = Self.shippedEntries
        let baseline = try decode(Self.document(shipped))
        #expect(baseline.count == PrintGauge.allCases.count)

        // A gauge listed twice — the same id, and its legacy long spelling.
        #expect(throws: GaugeConfigError.duplicateGauge("8mm")) {
            _ = try decode(Self.document(shipped + [("8mm", "2.0", "0.55")]))
        }
        #expect(throws: GaugeConfigError.duplicateGauge("8mm")) {
            _ = try decode(Self.document(shipped + [("eightMillimetre", "2.0", "0.55")]))
        }
        // A gauge with no entry at all.
        #expect(throws: GaugeConfigError.missingGauges(["75mm"])) {
            _ = try decode(Self.document(shipped.filter { $0.gauge != "75mm" }))
        }
        #expect(throws: GaugeConfigError.missingGauges(["8mm", "16mm", "35mm", "75mm"])) {
            _ = try decode(Self.document([]))
        }
        // Zero and negative multipliers.
        #expect(throws: GaugeConfigError.invalidMultiplier(gauge: "35mm", field: "sizeMultiplier", value: 0)) {
            _ = try decode(Self.document(Self.replacing(shipped, gauge: "35mm", size: "0")))
        }
        #expect(throws: GaugeConfigError.invalidMultiplier(gauge: "75mm", field: "amplitudeMultiplier", value: -0.165)) {
            _ = try decode(Self.document(Self.replacing(shipped, gauge: "75mm", amplitude: "-0.165")))
        }
        // An unsupported schema version is not silently read as version 1.
        #expect(throws: GaugeConfigError.unsupportedSchemaVersion(2)) {
            _ = try decode(Self.document(shipped, schemaVersion: 2))
        }
        // Unknown gauge identifiers, a non-finite number and a missing field all
        // fail to decode rather than falling back to a default entry.
        #expect(throws: (any Error).self) {
            _ = try decode(Self.document(shipped + [("9mm", "1.0", "0.2")]))
        }
        #expect(throws: (any Error).self) {
            _ = try decode(Self.document(Self.replacing(shipped, gauge: "8mm", size: "1e400")))
        }
        #expect(throws: (any Error).self) {
            _ = try decode("""
            {"schemaVersion": 1, "gauges": [{"gauge": "8mm", "sizeMultiplier": 2.0}]}
            """)
        }
    }

    // MARK: - Size axis

    @Test func gaugeSizeAxisIsMonotonicAnd35mmIsTheDefault() {
        // Nominal multipliers are strictly monotonic across the ladder.
        let multipliers = PrintGauge.allCases.sorted { $0.sizeMultiplier < $1.sizeMultiplier }
            .map(\.sizeMultiplier)
        #expect(multipliers == [0.5, 0.9, 1.35, 2.0], "unexpected ladder: \(multipliers)")
        // 35mm is the middle of the ladder and the render default.
        #expect(PrintGauge.neutral == .thirtyFiveMillimetre)
        // Effective footprints are ordered across the whole ladder.
        let stock: Float = 1.3
        let fine = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .seventyFiveMillimetre)
        let neutral = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .thirtyFiveMillimetre)
        let medium = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .sixteenMillimetre)
        let coarse = GrainModel.effectiveSize(stockGrainSize: stock, gauge: .eightMillimetre)
        #expect(fine < neutral && neutral < medium && medium < coarse,
                "footprint must grow 75mm < 35mm < 16mm < 8mm: \(fine), \(neutral), \(medium), \(coarse)")
        #expect(coarse >= neutral * 2, "8mm should be a real step up: \(neutral) -> \(coarse)")
    }

    /// 8mm, 16mm and 35mm land on exactly half their previous footprint on both
    /// shipped stocks; the safety bounds are the pre-tuning ones and do not clip
    /// those rungs.
    @Test func coarseThroughNeutralGaugesHalveThePreviousFootprintOnEveryShippedStock() {
        #expect(GrainModel.footprintFloor == 0.95, "the safety floor must stay at its origin/dev value")
        #expect(GrainModel.footprintCeiling == 16.0, "the safety ceiling must stay at its origin/dev value")
        let unclamped: [PrintGauge] = [.eightMillimetre, .sixteenMillimetre, .thirtyFiveMillimetre]
        for stockSize in Self.shippedStockSizes {
            for gauge in unclamped {
                let previousSize = Self.previousSizes[gauge] ?? 0
                let previousFootprint = previousSize * stockSize
                let footprint = GrainModel.effectiveSize(stockGrainSize: stockSize, gauge: gauge)
                #expect(footprint > GrainModel.footprintFloor,
                        "\(gauge.rawValue) on \(stockSize) must not reach the floor: \(footprint)")
                #expect(abs(footprint - previousFootprint / 2) < tolerance,
                        "\(gauge.rawValue) on \(stockSize): \(footprint) vs half of \(previousFootprint)")
            }
        }
    }

    /// The unchanged floor means the finest gauge cannot reach exactly half of
    /// its previous footprint on either shipped stock: 0.5 × 1.15 and 0.5 × 1.3
    /// are both under 0.95, so the delivered footprint stops at the floor.
    @Test func finestGaugeStopsAtTheFloorInsteadOfExactlyHalving() {
        for stockSize in Self.shippedStockSizes {
            let previousFootprint = stockSize * (Self.previousSizes[.seventyFiveMillimetre] ?? 0)
            let requested = previousFootprint / 2
            #expect(requested < GrainModel.footprintFloor,
                    "the requested half (\(requested)) is under the floor by design")
            let footprint = GrainModel.effectiveSize(stockGrainSize: stockSize,
                                                    gauge: .seventyFiveMillimetre)
            #expect(abs(footprint - GrainModel.footprintFloor) < tolerance)
            #expect(footprint > requested + tolerance,
                    "75mm on \(stockSize) cannot deliver exactly half: the floor pins it at \(footprint)")
        }
        // No combination may fall below the unchanged floor, and none above the ceiling.
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 0.5, gauge: .seventyFiveMillimetre) - 0.95) < tolerance)
        #expect(abs(GrainModel.effectiveSize(stockGrainSize: 0.7, gauge: .seventyFiveMillimetre) - 0.95) < tolerance)
        #expect(GrainModel.effectiveSize(stockGrainSize: 12, gauge: .eightMillimetre) == GrainModel.footprintCeiling)
    }

    // MARK: - Presence axis

    @Test func gaugeOwnsPresenceAcrossTheLadder() {
        let ladder: [PrintGauge] = [.eightMillimetre, .sixteenMillimetre,
                                    .thirtyFiveMillimetre, .seventyFiveMillimetre]
        let amounts = ladder.map { GrainModel.amount(gauge: $0) }
        // Presence falls strictly from the coarsest rung to the finest.
        #expect(zip(amounts, amounts.dropFirst()).allSatisfy { $0 > $1 },
                "presence must fall toward the fine end: \(amounts)")
        // Realized amount is baseAmount times the gauge's presence multiplier.
        for (index, gauge) in ladder.enumerated() {
            let expected = GrainModel.baseAmount * gauge.amplitudeMultiplier
            #expect(abs(amounts[index] - expected) < tolerance)
        }
    }

    /// Presence follows the shipped lift over the previous ladder at every edge
    /// boost, and the single loudness scale stays at 0.55. 8mm, 16mm and 75mm
    /// ship 10% louder; 35mm ships the larger lift that keeps its card-size
    /// grain above the 8-bit floor at half its previous footprint.
    @Test func presenceFollowsTheShippedLiftOverThePreviousLadder() {
        #expect(GrainModel.baseAmount == 0.55)
        for gauge in PrintGauge.allCases {
            let previousAmplitude = Self.previousAmplitudes[gauge] ?? 0
            let lift = Self.presenceLift[gauge] ?? 1
            #expect(abs(gauge.amplitudeMultiplier - previousAmplitude * lift) < tolerance,
                    "gauge \(gauge): amplitude \(gauge.amplitudeMultiplier) must be \(previousAmplitude * lift)")
            for edgeFactor: Float in [1, 3, 4] {
                let previous = GrainModel.baseAmount * previousAmplitude * edgeFactor
                #expect(abs(GrainModel.amount(gauge: gauge, edgeFactor: edgeFactor) - previous * lift) < tolerance)
            }
        }
    }

    @Test func isoDoesNotScaleGrain() {
        // Presence depends only on the gauge and baseAmount; there is no ISO term.
        let reference = GrainModel.amount(gauge: .sixteenMillimetre)
        let coarse = GrainModel.amount(gauge: .eightMillimetre)
        #expect(abs(reference - GrainModel.baseAmount
                    * PrintGauge.sixteenMillimetre.amplitudeMultiplier) < tolerance)
        #expect(abs(coarse - GrainModel.baseAmount
                    * PrintGauge.eightMillimetre.amplitudeMultiplier) < tolerance)
    }

    // MARK: - Document builders

    private typealias Entry = (gauge: String, size: String, amplitude: String)

    private static let shippedEntries: [Entry] = [
        ("8mm", "2.0", "0.55"),
        ("16mm", "1.35", "0.396"),
        ("35mm", "0.9", "0.36"),
        ("75mm", "0.5", "0.165")
    ]

    private static func document(_ entries: [Entry], schemaVersion: Int = 1) -> String {
        let body = entries.map {
            #"{"gauge": "\#($0.gauge)", "sizeMultiplier": \#($0.size), "amplitudeMultiplier": \#($0.amplitude)}"#
        }.joined(separator: ",\n    ")
        return """
        {
          "schemaVersion": \(schemaVersion),
          "gauges": [
            \(body)
          ]
        }
        """
    }

    private static func replacing(_ entries: [Entry], gauge: String,
                                 size: String? = nil,
                                 amplitude: String? = nil) -> [Entry] {
        entries.map {
            guard $0.gauge == gauge else { return $0 }
            return ($0.gauge, size ?? $0.size, amplitude ?? $0.amplitude)
        }
    }
}
