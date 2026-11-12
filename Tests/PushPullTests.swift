import Foundation
import Metal
import Testing

/// Contracts for render-time push/pull: the stop ladder, the meter-driven
/// automatic rule, the Apple Log 2 gain maths, and the fact that a pulled or
/// pushed render is recorded in the delivered metadata.
struct PushPullTests {
    // MARK: - Ladder

    @Test func ladderIsFixedStopsFromMinusThreeToPlusTwo() {
        #expect(PushPullStops.allCases.map(\.stops) == [-3, -2, -1, 0, 1, 2])
        #expect(PushPullStops.pullThree.displayName == "-3")
        #expect(PushPullStops.pullTwo.displayName == "-2")
        #expect(PushPullStops.pullOne.displayName == "-1")
        #expect(PushPullStops.none.displayName == "0")
        #expect(PushPullStops.pushOne.displayName == "+1")
        #expect(PushPullStops.pushTwo.displayName == "+2")
        #expect(PushPullStops.pullThree.isPull)
        #expect(PushPullStops.pullTwo.isPull)
        #expect(!PushPullStops.pushTwo.isPull)
        #expect(PushPullStops.none.linearGain == 1)
        #expect(PushPullStops.pullOne.linearGain == 0.5)
        #expect(PushPullStops.pullTwo.linearGain == 0.25)
        #expect(PushPullStops.pullThree.linearGain == 0.125)
        #expect(PushPullStops.pushTwo.linearGain == 4)
        // What the closed control reads: PUSH and PULL never share a word with
        // neutral, so the state is legible without opening the control.
        #expect(PushPullStops.allCases.map(\.effectWord) == ["PULL", "PULL", "PULL", "0", "PUSH", "PUSH"])
    }

    @Test func persistedStopsOutsideTheLadderSnapToTheNearestRung() throws {
        #expect(PushPullStops.nearest(to: -7) == .pullThree)
        #expect(PushPullStops.nearest(to: -4) == .pullThree)
        #expect(PushPullStops.nearest(to: -2) == .pullTwo)
        #expect(PushPullStops.nearest(to: 3) == .pushTwo)
        #expect(PushPullStops.nearest(to: -1) == .pullOne)
        // A future build's wider ladder must not make the queue unreadable.
        let decoded = try JSONDecoder().decode(PushPullStops.self, from: Data("9".utf8))
        #expect(decoded == .pushTwo)
    }

    // MARK: - Automatic selection

    @Test func autoPullsOnlyWhenTheMeterSitsAtLeastOneStopOverTarget() {
        let cases: [(Float?, PushPullStops)] = [
            (nil, .none),
            (.nan, .none),
            (-2.5, .none),
            (0, .none),
            (0.9, .none),
            (1.0, .pullOne),
            (1.4, .pullOne),
            (1.9, .pullOne),
            (2.0, .pullTwo),
            (3.4, .pullTwo)
        ]
        for (offset, expected) in cases {
            #expect(PushPullAutoPolicy.stops(forMeteredOffsetEV: offset) == expected,
                    "offset \(String(describing: offset)) should select \(expected)")
        }
    }

    @Test func automaticSelectionRecordsWhatTheMeterRead() {
        let resolved = PushPullExposure.automatic(meteredOffsetEV: 1.6)
        #expect(resolved.stops == .pullOne)
        #expect(resolved.origin == .automatic)
        #expect(resolved.meteredOffsetEV == 1.6)
        #expect(resolved.summary.hasPrefix("auto: pulled 1 stop"))

        // A missing reading is never a guess.
        let unresolved = PushPullExposure.automatic(meteredOffsetEV: nil)
        #expect(unresolved.isNeutral)
        #expect(unresolved.meteredOffsetEV == nil)
    }

    @Test func manualChoiceIgnoresTheMeter() {
        let preference = PushPullPreference(isAutomatic: false, manualStops: .pushTwo)
        let resolved = preference.resolved(meteredOffsetEV: 2.4)
        #expect(resolved.stops == .pushTwo)
        #expect(resolved.origin == .manual)
        #expect(resolved.meteredOffsetEV == nil)

        let automatic = PushPullPreference(isAutomatic: true, manualStops: .pushTwo)
        #expect(automatic.resolved(meteredOffsetEV: 2.4).stops == .pullTwo)
    }

    @Test func preferenceRoundTripsThroughItsPersistedString() {
        for preference in [PushPullPreference.standard,
                           PushPullPreference(isAutomatic: false, manualStops: .pullTwo),
                           PushPullPreference(isAutomatic: false, manualStops: .pushOne),
                           PushPullPreference(isAutomatic: false, manualStops: .none)] {
            #expect(PushPullPreference.decode(preference.encoded) == preference)
        }
        #expect(PushPullPreference.decode(nil) == .standard)
        #expect(PushPullPreference.decode("garbage") == .standard)
        #expect(PushPullPreference.decode("manual:12") == PushPullPreference(isAutomatic: false, manualStops: .pushTwo))
    }

    // MARK: - Transfer maths

    /// Codes spanning the toe, 18% grey, white and the log shoulder.
    private static let probes: [Double] = [0, 0.02, 0.05, 0.1, 0.15, 0.25, 0.4, 0.4882724585, 0.6, 0.75, 0.9, 1]

    @Test func neutralSettingIsExactlyTheInputCode() {
        for code in Self.probes {
            #expect(PushPullTransfer.gained(code: code, stops: .none) == code)
        }
    }

    @Test func oneStopHalvesSceneLightAndTwoStopsQuartersIt() {
        for code in Self.probes where code > 0.15 {
            let linear = PushPullTransfer.decode(code)
            #expect(abs(PushPullTransfer.decode(PushPullTransfer.gained(code: code, stops: .pullOne)) - linear * 0.5)
                < 1e-9, "code \(code) is not one stop darker")
            #expect(abs(PushPullTransfer.decode(PushPullTransfer.gained(code: code, stops: .pullTwo)) - linear * 0.25)
                < 1e-9, "code \(code) is not two stops darker")
            #expect(abs(PushPullTransfer.decode(PushPullTransfer.gained(code: code, stops: .pushTwo)) - linear * 4)
                < 1e-9, "code \(code) is not two stops brighter")
        }
    }

    @Test func pullNeverLiftsBlackAndNeverInvertsTheCurve() {
        // Apple Log 2 puts linear 0 at code 0.1505. A code-domain multiply would
        // have lifted every shadow; the linear-domain gain must darken.
        #expect(abs(PushPullTransfer.decode(0.1504707)) < 1e-5)
        for code in [0.0, 0.05, 0.1, 0.1504707, 0.2, 0.3] {
            let pulled = PushPullTransfer.gained(code: code, stops: .pullTwo)
            #expect(pulled <= code)
            #expect(pulled >= 0)
        }
        // Monotone ladder: darker stops never render brighter.
        for code in Self.probes {
            let values = PushPullStops.allCases.map { PushPullTransfer.gained(code: code, stops: $0) }
            #expect(values == values.sorted(), "push/pull order inverted at code \(code)")
        }
    }

    @Test func transferRoundTripsAgainstTheAppleLog2Curve() {
        // Sanity against the published curve: 18% grey is code 0.4883 and white
        // is 0.6946, so a -1 stop at 18% grey lands on the same code as 9% grey.
        #expect(abs(PushPullTransfer.encode(0.18) - 0.4882724585) < 1e-9)
        #expect(abs(PushPullTransfer.encode(1.0) - 0.6945529831) < 1e-9)
        #expect(abs(PushPullTransfer.gained(code: 0.4882724585, stops: .pullOne)
            - PushPullTransfer.encode(0.09)) < 1e-9)
    }

    // MARK: - Shader

    /// The render applies the push/pull in FRONT of the emulsion — inside
    /// `spatial.metal`'s halation ladder — so that kernel, not the LUT pass, is
    /// where the curve has to be pinned. `spatial_halation_apply` with zero
    /// halation strength and no diffusion is exactly the exposure curve.
    @Test func spatialShaderAppliesTheSameCurveAsTheSwiftFunction() throws {
        try Self.withPipeline { device, pipeline, queue in
            for stops in PushPullStops.allCases where stops != .none {
                for ceiling in [Float(PushPullTransfer.clipWhite), Float(3.0)] {
                    let ramp = (0...128).map { PushPullTransfer.encode(Double(ceiling) * Double($0) / 128) }
                    let probes = (Self.probes + ramp).sorted()
                    let output = try Self.run(probes: probes.map { Float($0) },
                                              stops: stops, ceiling: ceiling,
                                              device: device, pipeline: pipeline, queue: queue)
                    if !stops.isPull {
                        #expect(output == output.sorted(), "positive push inverted a gradient at ceiling \(ceiling)")
                    }
                    for (index, code) in probes.enumerated() {
                        let expected = PushPullTransfer.gained(code: code, stops: stops,
                                                               ceiling: Double(ceiling))
                        // 1e-4 absorbs the encode/decode round trip's float error.
                        #expect(abs(Double(output[index]) - expected) < 1e-4,
                                "stops \(stops.stops) ceiling \(ceiling) at code \(code): shader \(output[index]) vs swift \(expected)")
                    }
                }
            }
        }
    }

    /// The point of the curve: a truly clipped highlight does not move, so it
    /// stays white and keeps driving halation instead of being pulled into the
    /// stock's cast.
    @Test func clippedHighlightHoldsAtWhiteUnderAPull() {
        let ceiling = PushPullTransfer.clipWhite
        // The clip ceiling is code 1.0, and it is a fixed point of every stop.
        let clipped = PushPullTransfer.encode(ceiling)
        #expect(clipped > 0.99 && clipped <= 1.0)
        for stops in PushPullStops.allCases {
            // Within the float round trip of the ceiling code, the highlight does
            // not move. Without the hold a four-stop pull would drag it to ~0.74.
            #expect(abs(PushPullTransfer.gained(code: clipped, stops: stops, ceiling: ceiling) - clipped) < 1e-3,
                    "a clipped highlight moved under \(stops.displayName)")
        }
        #expect(PushPullTransfer.gained(code: clipped, stops: .pullThree) < 0.9,
                "the flat pull should have dragged the highlight down, so the hold is what protects it")
        // A midtone well below the clip still moves the full amount: one stop at
        // 18% grey lands on the same code as 9% grey, exactly as the flat curve.
        let mid = PushPullTransfer.encode(0.18)
        #expect(abs(PushPullTransfer.gained(code: mid, stops: .pullOne, ceiling: ceiling)
            - PushPullTransfer.encode(0.09)) < 1e-9)
        // And the ladder stays monotone at every code, so darker stops never
        // render brighter.
        for code in Self.probes {
            let values = PushPullStops.allCases.map {
                PushPullTransfer.gained(code: code, stops: $0, ceiling: ceiling)
            }
            #expect(values == values.sorted(), "push/pull order inverted at code \(code)")
        }
    }

    @Test func positivePushIsMonotoneBoundedAndContinuousThroughTheCeiling() {
        for ceiling in [1.0, 3.0, PushPullTransfer.clipWhite] {
            for stops in [PushPullStops.pushOne, .pushTwo] {
                var previous = 0.0
                // Includes the ceiling, the reported 1.5/2.25/3 regression, and above-ceiling identity.
                for index in 0...320 {
                    let linear = ceiling * Double(index) / 256
                    let code = PushPullTransfer.encode(linear)
                    let result = PushPullTransfer.decode(
                        PushPullTransfer.gained(code: code, stops: stops, ceiling: ceiling))
                    let expected = linear >= ceiling ? linear
                        : linear * stops.linearGain / (1 + (stops.linearGain - 1) * linear / ceiling)
                    #expect(abs(result - expected) < 1e-9)
                    #expect(result >= previous - 1e-9)
                    #expect(result >= linear - 1e-9)
                    #expect(result <= max(linear, ceiling) + 1e-9)
                    previous = result
                }
                // Full flat midtone gain is a pull-only expectation. A bounded push
                // already compresses at grey; flat gain is its limit near black.
                let midtone = 0.18
                let pushed = PushPullTransfer.decode(PushPullTransfer.gained(
                    code: PushPullTransfer.encode(midtone), stops: stops, ceiling: ceiling))
                #expect(pushed > midtone && pushed < midtone * stops.linearGain)
            }
        }
    }

    @Test func positivePushWithInvalidCeilingFallsBackToFlatGain() throws {
        try Self.withPipeline { device, pipeline, queue in
            for stops in [PushPullStops.pushOne, .pushTwo] {
                for ceiling in [Float(0), -1, .nan, .infinity, -.infinity] {
                    let output = try Self.run(probes: Self.probes.map { Float($0) },
                                              stops: stops, ceiling: ceiling,
                                              device: device, pipeline: pipeline, queue: queue)
                    for (index, code) in Self.probes.enumerated() {
                        // The production apply pass floors signed-black light at zero.
                        let expected = PushPullTransfer.encode(max(0, PushPullTransfer.decode(code) * stops.linearGain))
                        let mirrored = PushPullTransfer.gained(code: code, stops: stops, ceiling: Double(ceiling))
                        #expect(abs(mirrored - expected) < 1e-9)
                        #expect(abs(Double(output[index]) - expected) < 1e-4)
                    }
                }
            }
        }
    }

    // MARK: - Measuring the source's ceiling

    /// The take's ceiling is MEASURED, not assumed. The reported bug: a hazy sky
    /// carries ~3x white, and holding at Apple Log 2's 12x — the authored
    /// fallback, and the top of the *recording* range rather than of this take —
    /// let a three-stop pull drag it down to an eighth of its light, which is
    /// what put the stock's cast on highlights that were not recoverable anyway.
    @Test func takeCeilingHoldsAHighlightTheAuthoredFallbackWouldDragDown() {
        let sky = 3.3
        let code = PushPullTransfer.encode(sky)
        // At the measured ceiling the pull has nothing to recover, so the sky
        // stays exactly where the film put it, at every stop.
        for stops in PushPullStops.allCases {
            let held = PushPullTransfer.gained(code: code, stops: stops, ceiling: sky)
            #expect(abs(PushPullTransfer.decode(held) - sky) < 1e-6,
                    "the measured ceiling moved under \(stops.displayName)")
        }
        // The 12x fallback holds nothing at 3.3x white: it takes the full pull.
        let dragged = PushPullTransfer.gained(code: code, stops: .pullThree,
                                              ceiling: PushPullTransfer.clipWhite)
        #expect(abs(PushPullTransfer.decode(dragged) - sky / 8) < 1e-6)
    }

    /// The statistic itself: the 99.99th percentile of the peak channel, so one
    /// blown specular cannot hold a whole take down at the top of the format.
    @Test func measuredCeilingIsTheHighlightPercentileNotTheHotPixel() throws {
        let white = Float(PushPullTransfer.encode(1.0))
        let blown = Float(PushPullTransfer.encode(PushPullTransfer.clipWhite))
        let ceiling = try #require(PushPullTransfer.measuredHighlightCeiling(
            peakCodes: [Float](repeating: white, count: 20_000) + [blown]))
        #expect(abs(Double(ceiling) - 1.0) < 0.01,
                "one hot pixel set the ceiling: \(ceiling)")
        // A frame blown all over reports the top of the range, which is what a
        // genuinely clipped take looks like.
        let allBlown = try #require(PushPullTransfer.measuredHighlightCeiling(
            peakCodes: [Float](repeating: blown, count: 20_000)))
        #expect(abs(Double(allBlown) - PushPullTransfer.clipWhite) < 0.01)
    }

    /// A dim frame has nothing blown in it, so its ceiling floors at white and a
    /// pull darkens the whole scene — holding the top of an underlit range would
    /// flatten exactly the frames a pull is not for.
    @Test func dimTakeCeilingFloorsAtWhite() throws {
        let dim = Float(PushPullTransfer.encode(0.3))
        let ceiling = try #require(PushPullTransfer.measuredHighlightCeiling(
            peakCodes: [Float](repeating: dim, count: 20_000)))
        #expect(ceiling == 1)
    }

    @Test func measuredCeilingRejectsAnUnusableSample() {
        #expect(PushPullTransfer.measuredHighlightCeiling(peakCodes: []) == nil)
        #expect(PushPullTransfer.measuredHighlightCeiling(
            peakCodes: [.nan, .infinity, -.infinity]) == nil)
        // Codes below the curve's black offset carry no scene light.
        #expect(PushPullTransfer.measuredHighlightCeiling(peakCodes: [0, -0.02]) == nil)
    }

    /// A still keeps its own measured headroom and a take its measurement; only a
    /// source with neither falls back to the authored clip white.
    @Test func exposureCeilingPrefersTheMeasurementOverTheAuthoredFallback() {
        #expect(SpatialEffectsStage.halationCeiling(sceneLiftStops: 0, headroom: nil,
                                                    highlightCeiling: 3.3) == 3.3)
        #expect(SpatialEffectsStage.halationCeiling(sceneLiftStops: 0, headroom: 2.5) == 2.5)
        #expect(SpatialEffectsStage.halationCeiling(sceneLiftStops: 0)
                == SpatialEffectsStage.appleLog2ClipWhite)
        // A measurement of zero or nonsense is not a ceiling.
        #expect(SpatialEffectsStage.halationCeiling(sceneLiftStops: 0, headroom: 0)
                == SpatialEffectsStage.appleLog2ClipWhite)
        #expect(SpatialEffectsStage.halationCeiling(sceneLiftStops: 0, highlightCeiling: .nan)
                == SpatialEffectsStage.appleLog2ClipWhite)
    }

    // MARK: - Config and metadata

    @Test func stockOverrideKeepsRecipeAndRecordsThePull() throws {
        let stock = try #require(try Self.loadStocks().first)
        let pulled = stock.overridingPushPull(.manual(.pullTwo))
        #expect(pulled.recipe == stock.recipe)
        #expect(pulled.displayName == stock.displayName)
        #expect(pulled.effectivePushPull.stops == .pullTwo)
        #expect(stock.effectivePushPull == .neutral, "overriding returns a copy")
        try pulled.validate()

        let values = try RenderMovieMetadata.recipeValues(config: pulled)
        #expect(values["push-pull"] == "pulled")
        #expect(values["push-pull-stops"] == "-2")
        #expect(values["push-pull-mode"] == "manual")
        #expect(values["push-pull-linear-gain"] == "0.25")
        #expect(values["push-pull-metered-offset-ev"] == nil)

        let items = try RenderMovieMetadata.make(config: pulled)
        let item = try #require(items.first { ($0.key as? String) == "com.filmemulation.push-pull-stops" })
        #expect(item.value as? String == "-2")
    }

    @Test func automaticMetadataStatesTheMeterReading() throws {
        let stock = try #require(try Self.loadStocks().first)
        let config = stock.overridingPushPull(.automatic(meteredOffsetEV: 2.2))
        let values = try RenderMovieMetadata.recipeValues(config: config)
        #expect(values["push-pull"] == "pulled")
        #expect(values["push-pull-stops"] == "-2")
        #expect(values["push-pull-mode"] == "automatic")
        #expect(values["push-pull-metered-offset-ev"] == "2.2")

        // The full recipe snapshot carries the setting as well, so the
        // diagnostics manifest can be read back into a render.
        let json = try #require(values["render-settings"])
        let snapshot = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self,
                                                from: Data(json.utf8))
        #expect(snapshot.config.effectivePushPull == config.effectivePushPull)
    }

    @Test func neutralRenderRecordsThatNothingWasPulled() throws {
        let stock = try #require(try Self.loadStocks().first)
        let values = try RenderMovieMetadata.recipeValues(config: stock)
        #expect(values["push-pull"] == "normal")
        #expect(values["push-pull-stops"] == "0")
    }

    // MARK: - Queue

    @Test func queueJobCarriesThePushPullAndOldLegacyJSONStaysReadable() throws {
        let job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/take.mov"), stockId: "kodak5219",
                            iso: 500, printGauge: .sixteenMillimetre,
                            pushPull: .automatic(meteredOffsetEV: 1.2))
        let decoded = try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.pushPull?.stops == .pullOne)
        #expect(decoded.pushPull?.origin == .automatic)

        // A queue written before the control existed must still decode, and it
        // must render neutral rather than failing.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "pushPull")
        let legacy = try JSONDecoder().decode(RenderJob.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.pushPull == nil)
        #expect((legacy.pushPull ?? .neutral).stops == .none)
    }

    @MainActor @Test func reRenderReadsTheValueStoredOnTheJob() throws {
        let library = FilmStockLibrary(userDefaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        try library.load(from: TestRepository.url(for: "App/Resources/stocks.json"))
        let stock = try #require(library.stocks.first)

        // What the queue does at render time: config(for:iso:gauge:pushPull:).
        let neutral = try #require(library.config(for: stock.stockId, iso: stock.defaultISO))
        #expect(neutral.effectivePushPull == .neutral)

        let reRendered = try #require(library.config(for: stock.stockId, iso: stock.defaultISO,
                                                     gauge: .thirtyFiveMillimetre,
                                                     pushPull: .manual(.pushOne)))
        #expect(reRendered.effectivePushPull.stops == .pushOne)
        #expect(reRendered.printGauge == .thirtyFiveMillimetre)
        #expect(reRendered.effectiveRecipe == stock.effectiveRecipe)
    }

    /// Developing an Apple Log 2 import after the fact must apply the same
    /// push/pull the camera would: the job carries it, and the renderer builds
    /// the config from the job. Before this the import job stored nothing and
    /// every developed import rendered neutral.
    @MainActor @Test func importedVideoCarriesThePushPullIntoTheRender() throws {
        let library = FilmStockLibrary(userDefaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        try library.load(from: TestRepository.url(for: "App/Resources/stocks.json"))
        let stock = try #require(library.stocks.first)

        library.setPushPull(PushPullPreference(isAutomatic: false, manualStops: .pullTwo), for: stock.stockId)
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-queue.json")
        defer { try? FileManager.default.removeItem(at: queueURL) }
        let queue = RenderQueueViewModel(persistenceURL: queueURL)
        queue.library = library

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        try Data(repeating: 0, count: 64).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let id = try #require(queue.enqueueImportedVideo(
            sourceURL: source, stockId: stock.stockId, iso: stock.defaultISO, gauge: .thirtyFiveMillimetre
        ))
        let job = try #require(queue.jobs.first { $0.id == id })
        #expect(job.isImportedVideo == true)
        // The stock's persisted manual pull is what a develop applies.
        #expect(job.pushPull?.stops == .pullTwo)

        // And it reaches the renderer's config, which is what pass1 reads.
        let config = try #require(library.config(for: job.stockId, iso: job.iso, gauge: job.printGauge,
                                                 pushPull: job.pushPull ?? .neutral))
        #expect(config.effectivePushPull.stops == .pullTwo)
    }

    // MARK: - Helpers

    private static func loadStocks() throws -> [FilmStockConfig] {
        let data = try Data(contentsOf: TestRepository.url(for: "App/Resources/stocks.json"))
        struct Container: Decodable { let stocks: [FilmStockConfig] }
        return try JSONDecoder().decode(Container.self, from: data).stocks
    }

    private struct GPU {
        let device: MTLDevice
        let pipeline: MTLComputePipelineState
        let queue: MTLCommandQueue
    }

    private static var root: URL { TestRepository.root }

    private static func withPipeline<T>(_ body: (MTLDevice, MTLComputePipelineState, MTLCommandQueue) throws -> T) throws -> T {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try String(contentsOf: root.appendingPathComponent("Resources/Shaders/spatial.metal"),
                                encoding: .utf8)
        let header = try String(contentsOf: TestRepository.root.appendingPathComponent("Resources/Shaders/hlg-input.h"), encoding: .utf8)
        let library = try device.makeLibrary(source: source.replacingOccurrences(of: "#include \"hlg-input.h\"", with: header), options: nil)
        let function = try #require(library.makeFunction(name: "spatial_halation_apply"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        return try body(device, pipeline, queue)
    }

    /// Runs `spatial_halation_apply` with halation disabled and no diffusion, so
    /// the only thing between input code and output code is the exposure curve.
    /// The masks are real textures, but strength zero multiplies their
    /// contribution away, so they cannot affect the result.
    private static func run(probes: [Float], stops: PushPullStops, ceiling: Float,
                            device: MTLDevice, pipeline: MTLComputePipelineState,
                            queue: MTLCommandQueue) throws -> [Float] {
        let width = probes.count
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: 1, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        inputDescriptor.storageMode = .shared
        let input = try #require(device.makeTexture(descriptor: inputDescriptor))
        var values = [Float]()
        for probe in probes {
            values.append(contentsOf: [probe, probe, probe, 1])
        }
        values.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size)
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: 1, mipmapped: false)
        outputDescriptor.usage = .shaderWrite
        outputDescriptor.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: outputDescriptor))

        // A 1x1 mask stands in for the three diffused layers and all four
        // diffusion levels. Sampled, never read: strength and amount are zero.
        func mask() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let red = try mask()
        let green = try mask()
        let blue = try mask()
        let levelTexture = try mask()

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(red, index: 1)
        encoder.setTexture(green, index: 2)
        encoder.setTexture(blue, index: 3)
        encoder.setTexture(output, index: 4)
        for level in 0..<4 { encoder.setTexture(levelTexture, index: 5 + level) }
        var strength: Float = 0
        var layerScale = SIMD3<Float>(0, 0, 0)
        var diffusionWeights = SIMD4<Float>(0, 0, 0, 0)
        var diffusionAmount: Float = 0
        var exposureStops = Float(stops.stops)
        var exposureCeiling = ceiling
        // Neutral: this harness measures the push/pull curve itself, so the
        // system's develop lift stays out of it.
        var postEmulsionStops: Float = 0
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
        encoder.setBytes(&diffusionWeights, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.setBytes(&diffusionAmount, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&exposureStops, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&exposureCeiling, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(&postEmulsionStops, length: MemoryLayout<Float>.size, index: 6)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var result = [Float](repeating: 0, count: width * 4)
        result.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                            from: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0)
        }
        return (0..<width).map { result[$0 * 4] }
    }
}
