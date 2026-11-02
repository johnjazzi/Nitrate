import Foundation
import Metal
import Testing

/// Contracts for render-time push/pull: the stop ladder, the meter-driven
/// automatic rule, the Apple Log 2 gain maths, and the fact that a pulled or
/// pushed render is recorded in the delivered metadata.
struct PushPullTests {
    // MARK: - Ladder

    @Test func ladderIsFixedStopsFromMinusTwoToPlusTwo() {
        #expect(PushPullStops.allCases.map(\.stops) == [-2, -1, 0, 1, 2])
        #expect(PushPullStops.pullTwo.displayName == "-2")
        #expect(PushPullStops.pullOne.displayName == "-1")
        #expect(PushPullStops.none.displayName == "0")
        #expect(PushPullStops.pushOne.displayName == "+1")
        #expect(PushPullStops.pushTwo.displayName == "+2")
        #expect(PushPullStops.pullTwo.isPull)
        #expect(!PushPullStops.pushTwo.isPull)
        #expect(PushPullStops.none.linearGain == 1)
        #expect(PushPullStops.pullOne.linearGain == 0.5)
        #expect(PushPullStops.pullTwo.linearGain == 0.25)
        #expect(PushPullStops.pushTwo.linearGain == 4)
    }

    @Test func persistedStopsOutsideTheLadderSnapToTheNearestRung() throws {
        #expect(PushPullStops.nearest(to: -7) == .pullTwo)
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

    @Test func shaderAppliesTheSameCurveAsTheSwiftFunction() throws {
        try Self.withPipeline { device, pipeline, queue in
            for stops in PushPullStops.allCases where stops != .none {
                let output = try Self.run(probes: Self.probes.map { Float($0) },
                                          stops: stops, device: device, pipeline: pipeline, queue: queue)
                for (index, code) in Self.probes.enumerated() {
                    // The shipped cube's domain ends at code 1.0, so a push
                    // that lands above it is held at the top knot rather than
                    // wrapped or clipped to a wrong look.
                    let expected = min(PushPullTransfer.gained(code: code, stops: stops), 1)
                    // 1e-4 absorbs the cube's subtexel interpolation precision
                    // (a 33³ identity cube resamples the coordinate, it does not
                    // copy it bit-for-bit).
                    #expect(abs(Double(output[index]) - expected) < 1e-4,
                            "stops \(stops.stops) at code \(code): shader \(output[index]) vs swift \(expected)")
                }
            }
        }
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
        let source = try String(contentsOf: root.appendingPathComponent("Resources/Shaders/pipeline.metal"),
                                encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "pass1_lut_halation_glow"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        return try body(device, pipeline, queue)
    }

    /// Runs the production kernel with an identity cube and unity contrast, so
    /// the only thing between input code and output is the push/pull transform.
    private static func run(probes: [Float], stops: PushPullStops, device: MTLDevice,
                            pipeline: MTLComputePipelineState, queue: MTLCommandQueue) throws -> [Float] {
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

        // 33³ identity cube — the same grid the shipped cubes use, so the
        // sampler's subtexel precision does not dominate the comparison. A
        // 2x2x2 cube would quantize the coordinate to ~1/1024.
        let size = 33
        let lutDescriptor = MTLTextureDescriptor()
        lutDescriptor.textureType = .type3D
        lutDescriptor.pixelFormat = .rgba32Float
        lutDescriptor.width = size
        lutDescriptor.height = size
        lutDescriptor.depth = size
        lutDescriptor.storageMode = .shared
        lutDescriptor.usage = .shaderRead
        let lut = try #require(device.makeTexture(descriptor: lutDescriptor))
        var identity = [Float]()
        identity.reserveCapacity(size * size * size * 4)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    identity.append(contentsOf: [Float(red) / Float(size - 1),
                                                 Float(green) / Float(size - 1),
                                                 Float(blue) / Float(size - 1), 1])
                }
            }
        }
        identity.withUnsafeBytes { bytes in
            lut.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                        withBytes: bytes.baseAddress!, bytesPerRow: size * 16,
                        bytesPerImage: size * size * 16)
        }

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        var halation: Float = 0
        var glow: Float = 0
        var contrast: Float = 1
        var stopCount = Float(stops.stops)
        encoder.setBytes(&halation, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&glow, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&contrast, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&stopCount, length: MemoryLayout<Float>.size, index: 3)
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
