import Foundation
import Testing
import Metal
import simd

/// Behavioural tests for the lens diffusion node.
///
/// Two halves, deliberately:
///
///  * the PLAN is pure arithmetic and needs no GPU: radii are authored at a
///    1080p reference width, so the ladder depth and tap count have to stay
///    bounded as the frame grows, and the realized blur has to actually be the
///    radius that was asked for;
///  * the SHADER has to prove the look: scatter is neutral (unlike halation),
///    it preserves a uniform field exactly, it lowers local contrast, a wider
///    preset spreads further, the response is monotonic (no ring, no blocky
///    pyramid artefacts), and a bypassed preset is a true pass-through.
struct DiffusionTests {

    // MARK: - Stills

    /// A still keeps the gauge's RADIUS and mixes a smaller share of it.
    ///
    /// Radius is the physical spread, so it is not a taste knob; the amount is
    /// the mix, and a held frame reads softer than a moving one at the same
    /// amount. 16mm therefore stays 16 px and drops 0.30 to 0.15.
    @Test
    func stillShareKeepsTheRadiusAndMixesLess() throws {
        var stock = FilmStockConfig(stockId: "kokak", displayName: "s", category: .video,
                                    lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                    grainSize: 1, defaultISO: 250)
        stock.printGauge = .sixteenMillimetre
        stock.stillDiffusionScale = 0.5

        let take = stock.effectiveDiffusion
        let still = stock.effectiveStillDiffusion
        #expect(take.preset == .radius16)
        #expect(take.amount == 0.3)
        #expect(still.preset == take.preset, "the radius is physical and must not move")
        #expect(abs(still.amount - 0.15) < 0.0001)

        // A stock with no still share keeps the take's amount exactly.
        stock.stillDiffusionScale = nil
        #expect(stock.effectiveStillDiffusion == take)
    }

    /// The share must not resurrect a node that was meant to be off, and must
    /// not soften a bypassed gauge into an allocation.
    @Test
    func stillShareNeverEnablesABypassedNode() {
        for gauge in [PrintGauge.seventyFiveMillimetre] {
            var stock = FilmStockConfig(stockId: "k", displayName: "s", category: .video,
                                        lutName: "x.cube", halationStrength: 2.52, glowStrength: 0.1,
                                        grainSize: 1, defaultISO: 250)
            stock.printGauge = gauge
            stock.stillDiffusionScale = 0.5
            #expect(!stock.effectiveStillDiffusion.isEnabled)
            #expect(stock.effectiveStillDiffusion.plan(sourceWidth: 1920) == nil)
        }
    }

    /// Both shipped catalogs hold the stills back by the same share, and the
    /// take's own amount is untouched.
    @Test
    func shippedStocksHoldDiffusionBackOnStills() throws {
        for path in ["App/Resources/stocks.json", "Resources/stocks.json"] {
            let url = TestRepository.root.appendingPathComponent(path)
            struct Container: Decodable { let stocks: [FilmStockConfig] }
            let stocks = try JSONDecoder().decode(Container.self, from: Data(contentsOf: url)).stocks
            for stock in stocks {
                #expect(stock.effectiveStillDiffusionScale == 0.5,
                        "\(stock.stockId): stills take half the diffusion amount")
                #expect(stock.effectiveStillDiffusion.amount
                        == stock.effectiveDiffusion.amount * 0.5,
                        "\(stock.stockId): the share scales the amount, not the radius")
            }
        }
    }

    // MARK: - Plan (no GPU)

    @Test
    func bypassedAndDisabledPresetsProduceNoPlan() {
        #expect(DiffusionSettings(preset: .off, amount: 0.8).plan(sourceWidth: 1920) == nil)
        #expect(DiffusionSettings(preset: .radius75, amount: 0.8).plan(sourceWidth: 1920) == nil)
        #expect(DiffusionSettings(preset: .radius35, amount: 0).plan(sourceWidth: 1920) == nil)
        #expect(DiffusionSettings(preset: .radius35, amount: 0.5).plan(sourceWidth: 1920) != nil)
        #expect(DiffusionPreset.radius75.isBypass, "75 must be registered but bypassed")
        #expect(DiffusionPreset.off.isBypass)
    }

    /// The realized radius is what the presets claim: 8/16/35 at a 1080p frame.
    /// The mixture slightly over-delivers because the pyramid's own downsample
    /// adds variance, so the assertion is a band, not equality.
    @Test
    func realizedRadiusTracksTheAuthoredPreset() throws {
        for preset in [DiffusionPreset.radius8, .radius16, .radius35] {
            let settings = DiffusionSettings(preset: preset, amount: 0.6)
            let plan = try #require(settings.plan(sourceWidth: 1920))
            let authored = try #require(preset.radiusPixels)
            let realized = plan.radiusPixels(atSourceWidth: 1920)
            let ratio = realized / authored
            #expect(ratio > 0.8 && ratio < 1.25,
                    "\(preset.title) realized \(realized) px for authored \(authored) px")
        }
    }

    /// Widen the frame and the ladder absorbs the extra reach instead of the
    /// kernel: that is the whole point of the pyramid. A direct Gaussian would
    /// need `2 * ceil(3 * sigma) + 1` taps — 106 at 4K — so the bound that
    /// matters is `maxTaps`, not a constant.
    @Test
    func ladderDepthAbsorbsResolutionInsteadOfTapCount() throws {
        let settings = DiffusionSettings(preset: .radius35, amount: 0.5)
        let hd = try #require(settings.plan(sourceWidth: 1920))
        let uhd = try #require(settings.plan(sourceWidth: 3840))

        #expect(hd.levels == DiffusionPlan.maxLevels, "1080p already needs the full ladder")
        #expect(uhd.levels == DiffusionPlan.maxLevels)
        #expect(uhd.taps <= DiffusionPlan.maxTaps)
        let directTaps = 2 * Int((3 * 17.5).rounded(.up)) + 1
        #expect(uhd.taps < directTaps / 3,
                "4K must buy reach with octaves, not taps (\(uhd.taps) vs \(directTaps) direct)")

        // Same look at both widths: the authored radius is expressed at 1080p.
        let hdRadius = hd.radiusPixels(atSourceWidth: 1920)
        let uhdRadius = uhd.radiusPixels(atSourceWidth: 3840)
        #expect(abs(hdRadius - uhdRadius) < hdRadius * 0.25,
                "4K radius \(uhdRadius) must track 1080p radius \(hdRadius)")
    }

    @Test
    func everyPlanIsAUsableKernel() throws {
        for preset in [DiffusionPreset.radius8, .radius16, .radius35] {
            for width in [320, 640, 1920, 3840] {
                let plan = try #require(DiffusionSettings(preset: preset, amount: 0.5).plan(sourceWidth: width))
                #expect(plan.levels >= 1 && plan.levels <= DiffusionPlan.maxLevels)
                #expect(plan.taps % 2 == 1, "a separable Gaussian needs a centre tap")
                #expect(plan.taps <= DiffusionPlan.maxTaps)
                #expect(plan.weights.count == plan.taps)
                let total = plan.weights.reduce(0, +)
                #expect(abs(total - 1) < 1e-4, "weights must normalize (was \(total))")
                #expect(plan.weights.allSatisfy { $0 > 0 })
                let levelTotal = plan.levelWeights.x + plan.levelWeights.y
                    + plan.levelWeights.z + plan.levelWeights.w
                #expect(abs(levelTotal - 1) < 1e-4, "level weights must normalize (was \(levelTotal))")
                #expect(plan.realizedSigmaLevelZero > 0)
            }
        }
    }

    /// The radii are derived, not chosen: one measured scatter radius, the
    /// format's own enlargement, and a single authored filter gain.
    @Test
    func radiusFollowsTheFormatEnlargement() {
        // 16mm has to be enlarged ~3.5x more than 35mm to fill the same frame.
        #expect(abs(DiffusionPhysics.enlargementRelativeTo35mm(.sixteenMillimetre) - 36.0 / 10.26) < 0.01)
        #expect(abs(DiffusionPhysics.enlargementRelativeTo35mm(.eightMillimetre) - 36.0 / 5.79) < 0.01)

        let eight = DiffusionPhysics.radiusPixels(.eightMillimetre)
        let sixteen = DiffusionPhysics.radiusPixels(.sixteenMillimetre)
        let thirtyFive = DiffusionPhysics.radiusPixels(.thirtyFiveMillimetre)
        let sixtyFive = DiffusionPhysics.radiusPixels(.seventyFiveMillimetre)
        #expect(eight > sixteen && sixteen > thirtyFive && thirtyFive > sixtyFive,
                "radius must fall with format: \(eight), \(sixteen), \(thirtyFive), \(sixtyFive)")
        // 20 um of scatter, x4 filter gain, at a 1080p-wide delivery.
        #expect(abs(thirtyFive - 4.27) < 0.3, "35mm lands at ~4 px (was \(thirtyFive))")
        #expect(abs(sixteen - 14.96) < 0.5, "16mm lands at ~15 px (was \(sixteen))")
        #expect(abs(eight - 26.5) < 0.6, "8mm lands at ~26 px (was \(eight))")

        // Rounded to the shipped rungs, with 75mm bypassed rather than rounded.
        #expect(DiffusionPhysics.preset(for: .eightMillimetre) == .radius35)
        #expect(DiffusionPhysics.preset(for: .sixteenMillimetre) == .radius16)
        #expect(DiffusionPhysics.preset(for: .thirtyFiveMillimetre) == .radius4)
        #expect(DiffusionPhysics.preset(for: .seventyFiveMillimetre) == .radius75)
    }

    // MARK: - Gauge ownership

    /// The print format IS the radius ladder, and it runs from the softest
    /// format to the sharpest: 8mm spreads furthest, 35mm least, and 75mm — the
    /// reference print — is bypassed.
    @Test
    func everyGaugeOwnsItsRadius() throws {
        #expect(PrintGauge.eightMillimetre.diffusionPreset == .radius35)
        #expect(PrintGauge.sixteenMillimetre.diffusionPreset == .radius16)
        #expect(PrintGauge.thirtyFiveMillimetre.diffusionPreset == .radius4)
        #expect(PrintGauge.seventyFiveMillimetre.diffusionPreset == .radius75)
        #expect(PrintGauge.seventyFiveMillimetre.diffusion.preset.isBypass)
        // The ladder is inverted against grain coarseness: the gauge with the
        // most grain spreads the most light, the sharpest rendered gauge least.
        let eight = try #require(PrintGauge.eightMillimetre.diffusionPreset.radiusPixels)
        let sixteen = try #require(PrintGauge.sixteenMillimetre.diffusionPreset.radiusPixels)
        let thirtyFive = try #require(PrintGauge.thirtyFiveMillimetre.diffusionPreset.radiusPixels)
        #expect(eight > sixteen && sixteen > thirtyFive,
                "radius must fall 8mm > 16mm > 35mm: \(eight), \(sixteen), \(thirtyFive)")
    }

    /// The shipped gauge document carries one diffusion setting per gauge — the
    /// ladder ships as authored data, not as code — the App and CLI copies are
    /// identical, and every rung states its own radius AND its own amount.
    @Test
    func shippedGaugesCarryTheirOwnDiffusionLadder() throws {
        let root = TestRepository.root
        let cliURL = root.appendingPathComponent("Resources/gauges.json")
        let appURL = root.appendingPathComponent("App/Resources/gauges.json")
        #expect(try Data(contentsOf: cliURL) == Data(contentsOf: appURL),
                "the App and CLI gauge ladders must stay identical")

        let resolved = try GaugeConfigLoader.load(contentsOf: cliURL)
        for gauge in PrintGauge.allCases {
            let tuning = try #require(resolved[gauge])
            #expect(tuning.diffusionPreset == gauge.diffusionPreset,
                    "\(gauge.rawValue) must ship its own radius")
            // The shipped starting ladder: softer format, wider and stronger.
            let shipped: [PrintGauge: (preset: DiffusionPreset, amount: Float)] = [
                .eightMillimetre: (.radius35, 0.5),
                .sixteenMillimetre: (.radius16, 0.3),
                .thirtyFiveMillimetre: (.radius4, 0.2),
                .seventyFiveMillimetre: (.radius75, 0)
            ]
            let expected = try #require(shipped[gauge])
            #expect(tuning.diffusionPreset == expected.preset,
                    "\(gauge.rawValue) radius: \(tuning.diffusionPreset.rawValue)")
            #expect(abs(tuning.diffusionAmount - expected.amount) < 1e-6,
                    "\(gauge.rawValue) amount: \(tuning.diffusionAmount)")
            // 75mm is the one gauge that renders nothing, by preset.
            #expect(tuning.diffusion.isEnabled == (gauge != .seventyFiveMillimetre))
        }
    }

    /// Switching gauge re-seeds the diffusion dials, exactly like grain size and
    /// presence, so a format change cannot leave a stale radius behind.
    @Test
    func gaugeSelectionReseedsDiffusion() {
        let stock = FilmStockConfig(stockId: "test", displayName: "Test", category: .video,
                                    lutName: "test.cube", halationStrength: 0, glowStrength: 0,
                                    grainSize: 1, defaultISO: 250)
        var parameters = PipelineRenderer.DebugFrameParameters(config: stock)
        #expect(parameters.diffusion.preset == PrintGauge.neutral.diffusionPreset)

        parameters.applyGauge(.eightMillimetre)
        #expect(parameters.diffusion.preset == .radius35)
        #expect(parameters.diffusion.amount == PrintGauge.eightMillimetre.diffusion.amount)

        parameters.applyGauge(.seventyFiveMillimetre)
        #expect(parameters.diffusion.preset == .radius75)
        #expect(!parameters.diffusion.isEnabled, "75mm must stay bypassed")
    }

    /// A stock that authors its own diffusion overrides the gauge's; one that
    /// does not inherits the gauge's.
    @Test
    func stockDiffusionOverridesTheGauge() {
        var stock = FilmStockConfig(stockId: "test", displayName: "Test", category: .video,
                                    lutName: "test.cube", halationStrength: 0, glowStrength: 0,
                                    grainSize: 1, defaultISO: 250)
        stock.printGauge = .sixteenMillimetre
        #expect(stock.effectiveDiffusion.preset == .radius16)

        stock.diffusion = DiffusionSettings(preset: .radius8, amount: 0.4)
        #expect(stock.effectiveDiffusion.preset == .radius8)
        #expect(stock.effectiveDiffusion.amount == 0.4)
    }

    // MARK: - Shader

    private static let side = 512
    private static let blockLower = 224
    private static let blockUpper = 288
    private static let surround: Double = 0.18
    private static let superwhite: Double = 3.0

    /// A superwhite block on an 18% surround, as Apple Log 2.
    private static func blockPixels() -> [Float16] {
        var pixels = [Float16]()
        pixels.reserveCapacity(side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let inBlock = column >= blockLower && column < blockUpper
                    && row >= blockLower && row < blockUpper
                let value = inBlock ? superwhite : surround
                pixels.append(SpatialEffectsTests.appleLogEncode(value))
                pixels.append(SpatialEffectsTests.appleLogEncode(value))
                pixels.append(SpatialEffectsTests.appleLogEncode(value))
                pixels.append(1)
            }
        }
        return pixels
    }

    private static func uniformPixels(_ value: Double) -> [Float16] {
        var pixels = [Float16](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            pixels[index * 4] = SpatialEffectsTests.appleLogEncode(value)
            pixels[index * 4 + 1] = SpatialEffectsTests.appleLogEncode(value)
            pixels[index * 4 + 2] = SpatialEffectsTests.appleLogEncode(value)
            pixels[index * 4 + 3] = 1
        }
        return pixels
    }

    private static func makeTexture(
        device: MTLDevice, width: Int, height: Int, pixels: [Float16]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * 8
            )
        }
        return texture
    }

    private static func readBack(
        _ texture: MTLTexture, queue: MTLCommandQueue, width: Int, height: Int
    ) throws -> [Float16] {
        if let synchronize = queue.makeCommandBuffer(), let blit = synchronize.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            synchronize.commit()
            synchronize.waitUntilCompleted()
        }
        var values = [Float16](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        return values
    }

    /// Both shader files, so the library carries the halation kernels the stage
    /// needs alongside the diffusion ones.
    private static func shaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let names = ["Resources/Shaders/spatial.metal", "Resources/Shaders/diffusion.metal"]
        let source = try names.map {
            try String(contentsOf: TestRepository.root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        return try device.makeLibrary(source: source, options: nil)
    }

    /// One spatial pass, decoded back to linear scene light.
    private static func runSpatial(
        device: MTLDevice, queue: MTLCommandQueue, pixels: [Float16],
        halationStrength: Float = 0, radiusFraction: Float = 0,
        diffusion: DiffusionSettings
    ) throws -> [Double] {
        let stage = try SpatialEffectsStage(device: device, library: shaderLibrary(device: device))
        let source = try makeTexture(device: device, width: side, height: side, pixels: pixels)
        let output = try #require(stage.applyHalation(
            source: source, commandQueue: queue,
            strength: halationStrength, radiusFraction: radiusFraction, layerScale: SIMD3<Float>(1, 1, 1),
            diffusion: diffusion, width: side, height: side
        ))
        let encoded = try readBack(output, queue: queue, width: side, height: side)
        var linear = [Double](repeating: 0, count: side * side * 3)
        for index in 0..<(side * side) {
            for channel in 0..<3 {
                linear[index * 3 + channel] = SpatialEffectsTests.appleLogDecode(Double(encoded[index * 4 + channel]))
            }
        }
        return linear
    }

    /// Diffusion only: halation strength 0, so the scatter measured here is the
    /// lens filter and nothing else.
    private static func runDiffusion(
        device: MTLDevice, queue: MTLCommandQueue, pixels: [Float16],
        diffusion: DiffusionSettings
    ) throws -> [Double] {
        try runSpatial(device: device, queue: queue, pixels: pixels, diffusion: diffusion)
    }

    private static func rowProfile(_ linear: [Double], row: Int, columns: Range<Int>) -> [Double] {
        columns.map { linear[(row * side + $0) * 3] }
    }

    /// Scatter is NEUTRAL: a diffusion filter spreads every channel alike, so the
    /// light that appears outside a white block is white too. Halation is the
    /// opposite (red-dominant), and the two must not be confused.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diffusionScattersNeutrallyOutsideTheHighlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let baseline = try Self.runDiffusion(device: device, queue: queue, pixels: Self.blockPixels(),
                                             diffusion: .disabled)
        let diffused = try Self.runDiffusion(
            device: device, queue: queue, pixels: Self.blockPixels(),
            diffusion: DiffusionSettings(preset: .radius35, amount: 0.6)
        )

        // A narrow band just outside the block, sampled inside it.
        let bandRow = Self.blockUpper + 6
        let band = (Self.blockLower + 16)..<(Self.blockUpper - 16)
        func mean(_ linear: [Double], channel: Int) -> Double {
            let values = band.map { linear[(bandRow * Self.side + $0) * 3 + channel] }
            return values.reduce(0, +) / Double(values.count)
        }

        for channel in 0..<3 {
            let added = mean(diffused, channel: channel) - mean(baseline, channel: channel)
            #expect(added > 0.005, "diffusion must add light outside the block (channel \(channel): \(added))")
        }
        let red = mean(diffused, channel: 0) - mean(baseline, channel: 0)
        let blue = mean(diffused, channel: 2) - mean(baseline, channel: 2)
        #expect(abs(red - blue) < max(0.01, red * 0.2),
                "diffusion scatter must be neutral (red \(red), blue \(blue))")
    }

    /// Local contrast falls: the block core is pulled toward the surround and the
    /// edge transition widens.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diffusionLowersLocalContrast() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let baseline = try Self.runDiffusion(device: device, queue: queue, pixels: Self.blockPixels(),
                                             diffusion: .disabled)
        let diffused = try Self.runDiffusion(
            device: device, queue: queue, pixels: Self.blockPixels(),
            diffusion: DiffusionSettings(preset: .radius35, amount: 0.7)
        )

        func value(_ linear: [Double], column: Int) -> Double {
            linear[((Self.blockLower + 32) * Self.side + column) * 3]
        }
        let centre = (Self.blockLower + Self.blockUpper) / 2
        #expect(value(diffused, column: centre) < value(baseline, column: centre),
                "diffusion must pull the block core down toward the surround")
        #expect(value(diffused, column: centre) > Self.surround,
                "diffusion must not flatten the block into the surround")
        // Below the block the light spreads; the baseline is a hard step.
        #expect(value(diffused, column: centre) > 0)
    }

    /// A uniform field is the invariant that catches a mis-normalized kernel: a
    /// weighted average of a constant is that constant, everywhere, including at
    /// the clamped edges.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diffusionPreservesAUniformField() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let linear = try Self.runDiffusion(
            device: device, queue: queue, pixels: Self.uniformPixels(Self.surround),
            diffusion: DiffusionSettings(preset: .radius35, amount: 1.0)
        )

        var worst = 0.0
        for row in stride(from: 0, to: Self.side, by: 7) {
            for column in stride(from: 0, to: Self.side, by: 7) {
                worst = max(worst, abs(linear[(row * Self.side + column) * 3] - Self.surround))
            }
        }
        #expect(worst < 0.002, "a uniform field must survive the ladder (worst error \(worst))")
    }

    /// Wider preset, further reach: the "increasing softness" ladder.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func widerPresetSpreadsFurther() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pixels = Self.blockPixels()
        // Just below the block: a step edge blurs to a higher value at a fixed
        // small distance as sigma grows, so the ladder reads monotonically here
        // even though the small presets barely reach further out.
        let row = Self.blockUpper + 3
        func band(_ linear: [Double]) -> Double {
            let columns = (Self.blockLower + 20)..<(Self.blockUpper - 20)
            let values = columns.map { linear[(row * Self.side + $0) * 3] }
            return values.reduce(0, +) / Double(values.count)
        }

        var previous = band(try Self.runDiffusion(device: device, queue: queue, pixels: pixels,
                                                 diffusion: .disabled))
        for preset in [DiffusionPreset.radius8, .radius16, .radius35] {
            let current = band(try Self.runDiffusion(
                device: device, queue: queue, pixels: pixels,
                diffusion: DiffusionSettings(preset: preset, amount: 0.6)
            ))
            #expect(current > previous,
                    "\(preset.title) must reach further than the previous preset (\(current) vs \(previous))")
            previous = current
        }
    }

    /// No ring, no blocky pyramid seams: the response falls monotonically away
    /// from the block. A bilinear-upsampled coarse level would show a step here.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diffusionResponseFallsMonotonicallyAwayFromTheSource() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let linear = try Self.runDiffusion(
            device: device, queue: queue, pixels: Self.blockPixels(),
            diffusion: DiffusionSettings(preset: .radius35, amount: 1.0)
        )

        let row = Self.blockLower + 32
        let profile = Self.rowProfile(linear, row: row, columns: (Self.blockUpper - 2)..<(Self.blockUpper + 40))
        for index in 1..<profile.count {
            // A 1.5% allowance absorbs float rounding in a falling tail.
            #expect(profile[index] <= profile[index - 1] * 1.015 + 1e-4,
                    "profile must not rise away from the source at index \(index) (\(profile[index - 1]) -> \(profile[index]))")
        }
    }

    /// The bypassed presets allocate nothing and change nothing: the stage hands
    /// back its input texture object rather than a re-encoded copy.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func bypassedPresetsAreATruePassThrough() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: Self.shaderLibrary(device: device))
        let source = try Self.makeTexture(device: device, width: Self.side, height: Self.side,
                                          pixels: Self.blockPixels())

        for preset in [DiffusionPreset.off, .radius75] {
            let output = try #require(stage.applyHalation(
                source: source, commandQueue: queue,
                strength: 0, radiusFraction: 0, layerScale: SIMD3<Float>(1, 1, 1),
                diffusion: DiffusionSettings(preset: preset, amount: 0.9),
                width: Self.side, height: Self.side
            ))
            #expect(output === source, "\(preset.title) must not render anything")
        }

        // A live preset with zero amount is equally a pass-through.
        let disabled = try #require(stage.applyHalation(
            source: source, commandQueue: queue,
            strength: 0, radiusFraction: 0, layerScale: SIMD3<Float>(1, 1, 1),
            diffusion: DiffusionSettings(preset: .radius35, amount: 0),
            width: Self.side, height: Self.side
        ))
        #expect(disabled === source)
    }

    /// Diffusion and halation share one decode/encode pass but stay independent
    /// effects: an enabled diffuser softens the frame AND leaves the halo's
    /// red-dominant far tail intact, rather than replacing it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diffusionComposesWithHalation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pixels = Self.blockPixels()
        let halationOnly = try Self.runSpatial(
            device: device, queue: queue, pixels: pixels,
            halationStrength: 2.0, radiusFraction: 0.02, diffusion: .disabled
        )
        let both = try Self.runSpatial(
            device: device, queue: queue, pixels: pixels,
            halationStrength: 2.0, radiusFraction: 0.02,
            diffusion: DiffusionSettings(preset: .radius16, amount: 0.5)
        )
        let plain = try Self.runSpatial(device: device, queue: queue, pixels: pixels,
                                        diffusion: .disabled)

        // Far field, well outside the block: halation is red-dominant there, and
        // that signature must survive the diffuser.
        let row = Self.blockUpper + 30
        let columns = (Self.blockLower + 8)..<(Self.blockUpper - 8)
        func far(_ linear: [Double], channel: Int) -> Double {
            let values = columns.map { linear[(row * Self.side + $0) * 3 + channel] }
            return values.reduce(0, +) / Double(values.count)
        }
        #expect(far(halationOnly, channel: 0) > far(plain, channel: 0),
                "halation must still add light with the node disabled")
        #expect(far(both, channel: 0) > far(both, channel: 2),
                "the halo must stay red-dominant when diffusion is enabled")
        #expect(far(both, channel: 0) > far(halationOnly, channel: 0) * 0.5,
                "diffusion must soften, not cancel, the halo")
    }
}
