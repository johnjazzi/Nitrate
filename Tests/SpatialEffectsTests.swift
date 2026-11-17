import Foundation
import Testing
import Metal
import simd

/// Behavioural tests for the spatial halation/glow stage (epic story 1.4).
///
/// Halation reads ungraded scene-linear RGB, splits each source's energy by
/// brightness, Gaussian-filters each bucket per channel, and adds it pre-LUT.
/// Tests cover channel isolation, source-dependent reach, colour-radius order,
/// smooth diagonal contours, linear addition and the prepare/apply contracts.
/// Glow remains an independent post-LUT effect.
struct SpatialEffectsTests {

    // MARK: - Fixtures and helpers

    /// Apple Log 2 encode — the inverse of the decode the shader applies.
    /// Constants are Apple's via OpenColorIO v2.6.0 `AppleCameras.cpp`, the same
    /// source the shader and the LUT generator use. Needed because halation now
    /// reads the UNGRADED frame, so fixtures are built as scene light and
    /// encoded, not written as graded pixels.
    static func appleLogEncode(_ linear: Double) -> Float16 {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236
        let beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        let code = linear >= rt
            ? delta + gamma * log2(linear + beta)
            : c * (linear - r0) * (linear - r0)
        return Float16(code)
    }

    /// Apple Log 2 decode, so read-back code values can be measured as the scene
    /// light they carry — the space halation is actually added in.
    static func appleLogDecode(_ code: Double) -> Double {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236
        let beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        let pt = c * (rt - r0) * (rt - r0)
        if code >= pt { return pow(2, (code - delta) / gamma) - beta }
        if code >= 0 { return (code / c).squareRoot() + r0 }
        return r0
    }

    /// RGBA16Float, CPU-readable texture with the given pixels.
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

    /// Build an Apple Log 2 encoded source from per-pixel linear scene light.
    private static func sourcePixels(
        width: Int, height: Int, _ value: (Int, Int) -> SIMD3<Double>
    ) -> [Float16] {
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let v = value(column, row)
                pixels.append(appleLogEncode(v.x))
                pixels.append(appleLogEncode(v.y))
                pixels.append(appleLogEncode(v.z))
                pixels.append(1)
            }
        }
        return pixels
    }

    /// Build a raw (non-encoded) RGBA16Float pixel array — for GRADED fixtures,
    /// which are already display-referred and must not be Apple Log encoded.
    private static func rawPixels(
        width: Int, height: Int, _ value: (Int, Int) -> SIMD3<Double>
    ) -> [Float16] {
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let v = value(column, row)
                pixels.append(Float16(v.x))
                pixels.append(Float16(v.y))
                pixels.append(Float16(v.z))
                pixels.append(1)
            }
        }
        return pixels
    }

    /// Synchronize then read an RGBA16Float texture back to CPU half floats.
    private static func readBack(
        _ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue,
        width: Int, height: Int
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

    /// Run `applyHalation` and return the ENCODED result (Apple Log 2).
    private static func runHalation(
        stage: SpatialEffectsStage, device: MTLDevice, queue: MTLCommandQueue,
        width: Int, height: Int, sourcePixels: [Float16],
        strength: Float, radiusFraction: Float, layerScale: SIMD3<Float>,
        growth: Float? = nil, onsets: SIMD3<Float>? = nil
    ) throws -> [Float16] {
        let input = try makeTexture(device: device, width: width, height: height, pixels: sourcePixels)
        let output = try #require(stage.applyHalation(
            source: input, commandQueue: queue,
            strength: strength, radiusFraction: radiusFraction, layerScale: layerScale,
            authoredOnsets: onsets, authoredGrowth: growth,
            width: width, height: height
        ))
        return try readBack(output, device: device, queue: queue, width: width, height: height)
    }

    /// Decode an RGBA16Float read-back to linear scene light as rgb triples.
    private static func decodedLinear(_ encoded: [Float16], count: Int) -> [Double] {
        var linear = [Double](repeating: 0, count: count * 3)
        for index in 0..<count {
            linear[index * 3] = appleLogDecode(Double(encoded[index * 4]))
            linear[index * 3 + 1] = appleLogDecode(Double(encoded[index * 4 + 1]))
            linear[index * 3 + 2] = appleLogDecode(Double(encoded[index * 4 + 2]))
        }
        return linear
    }

    /// Mean decoded-linear rgb over a rectangle.
    private static func linearMean(
        _ linear: [Double], width: Int, columns: Range<Int>, rows: Range<Int>
    ) -> SIMD3<Double> {
        var sum = SIMD3<Double>(0, 0, 0)
        var count = 0
        for row in rows {
            for column in columns {
                let index = (row * width + column) * 3
                sum += SIMD3(linear[index], linear[index + 1], linear[index + 2])
                count += 1
            }
        }
        let divisor = Double(max(count, 1))
        return sum / divisor
    }

    /// Compile the shipped spatial and diffusion shaders at runtime so the test
    /// exercises the kernels that actually ship. `SpatialEffectsStage` resolves
    /// its diffusion pipeline states at init, so the library has to carry both
    /// files even for a halation-only test.
    private static func shaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = try ["Resources/Shaders/spatial.metal", "Resources/Shaders/diffusion.metal"]
            .map { try String(contentsOf: TestRepository.root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        let header = try String(contentsOf: TestRepository.root.appendingPathComponent("Resources/Shaders/hlg-input.h"), encoding: .utf8)
        return try device.makeLibrary(source: source.replacingOccurrences(of: "#include \"hlg-input.h\"", with: header), options: nil)
    }

    // MARK: - Shared fixtures

    private static let side = 256
    private static let blockLower = 100
    private static let blockUpper = 156
    private static let surround: Double = 0.18
    private static let superwhite: Double = 3.0
    private static let tint = SIMD3<Float>(1.0, 0.32, 0.10)

    private static func blockSource(
        width: Int, height: Int, block: SIMD3<Double>
    ) -> [Float16] {
        sourcePixels(width: width, height: height) { column, row in
            let inBlock = column >= blockLower && column < blockUpper
                && row >= blockLower && row < blockUpper
            return inBlock ? block : SIMD3(surround, surround, surround)
        }
    }

    // MARK: - Halation: local, warm, physical

    /// Light appears outside the bright region, it is warm, and it is local.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationAddsWarmLocalLightOutsideTheHighlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.blockSource(width: Self.side, height: Self.side,
                                      block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: Self.side, height: Self.side, sourcePixels: source,
            strength: 0.5, radiusFraction: 0.012, layerScale: Self.tint
        )
        let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)

        // Band hugging the outside of the block (right edge x=156); dark in source.
        let adjacent = Self.linearMean(linear, width: Self.side, columns: 158..<178, rows: 100..<156)
        // Far corner, well beyond the halation radius.
        let far = Self.linearMean(linear, width: Self.side, columns: 5..<40, rows: 5..<40)

        let addedRed = adjacent.x - Self.surround
        let addedGreen = adjacent.y - Self.surround
        let addedBlue = adjacent.z - Self.surround

        #expect(addedRed > 0.002, "halation must add light outside the bright block (was \\(addedRed))")
        // Warm: red responds to the least light, green next; blue is below its
        // 4.0 knee at a 3.0x source and stays dark.
        #expect(addedRed > addedGreen + 0.0005, "red must dominate green (red \\(addedRed), green \\(addedGreen))")
        #expect(addedGreen > addedBlue + 0.0005, "green must dominate blue (green \\(addedGreen), blue \\(addedBlue))")

        // Far corner stays at the source level — the effect is local, not the
        // constant frame-wide lift the old per-pixel glow applied.
        #expect(abs(far.x - Self.surround) < 0.003, "far field must stay at the source level (was \\(far.x))")
        #expect(abs(far.z - Self.surround) < 0.003, "far field must stay at the source level (was \\(far.z))")
    }

    /// The source core gains light rather than being hollowed into a ring.
    ///
    /// Reflected light lands across the source's own footprint too, and because
    /// that energy accumulates it makes a very bright source read as *larger*.
    /// So the centre must gain light, and the added light at the centre must
    /// exceed the added light in the tail outside it. A ring (subtracting the
    /// source's own highlight) would fail both.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationBrightensSourceCoreInsteadOfHollowingIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.blockSource(width: Self.side, height: Self.side,
                                      block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: Self.side, height: Self.side, sourcePixels: source,
            strength: 0.5, radiusFraction: 0.012, layerScale: Self.tint
        )
        let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)

        let centre = Self.linearMean(linear, width: Self.side, columns: 118..<138, rows: 118..<138)
        let tail = Self.linearMean(linear, width: Self.side, columns: 70..<99, rows: 110..<146)

        let centreAdded = centre.x - Self.superwhite
        let tailAdded = tail.x - Self.surround

        #expect(tailAdded > 0.005, "the tail outside the source must still be lit (was \\(tailAdded))")
        #expect(centreAdded > 0, "the source core must gain light, not be hollowed (was \\(centreAdded))")
        #expect(centreAdded > tailAdded,
                "added light at the source centre (\\(centreAdded)) must exceed the tail (\\(tailAdded)) — the source grows, it is not a ring")
    }

    /// A clipped point light grows a WARM halo that reaches past its own
    /// footprint — the property the frame's brightest pixel is judged by.
    ///
    /// Sampled with the stock's own shipping numbers (strength, radius fraction,
    /// layer tint from `Resources/stocks.json`) and the scheme's own onset, so
    /// re-tuning any of them moves this test with the look instead of silently
    /// pinning an old one. The light is 8 px at 12x white in a 1920-wide frame:
    /// the hardest case for a halo, because a small source carries little energy
    /// and the half-resolution mask averages it down further.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func clippedPointLightHalatesWarmOutsideItsOwnFootprint() throws {
        struct Catalog: Decodable { let stocks: [FilmStockConfig] }
        let url = TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        let config = try #require(
            try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
                .stocks.first { $0.stockId == "kodak5219" },
            "kodak5219 stock configuration")

        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let width = 1920, height = 1080
        let surround = 0.02, size = 8
        let source = Self.sourcePixels(width: width, height: height) { column, row in
            let inside = abs(column - width / 2) < size / 2 && abs(row - height / 2) < size / 2
            let v = inside ? 12.0 : surround
            return SIMD3(v, v, v)
        }
        let input = try Self.makeTexture(device: device, width: width, height: height, pixels: source)
        let output = try #require(stage.applyHalation(
            source: input, commandQueue: queue,
            strength: config.effectiveHalationStrength,
            radiusFraction: config.effectiveHalationRadiusFraction,
            layerScale: config.halationTint,
            diffusion: .disabled,
            width: width, height: height))
        let linear = Self.decodedLinear(
            try Self.readBack(output, device: device, queue: queue, width: width, height: height),
            count: width * height)

        // Unlit background: anything lit out here is the emulsion, not the source.
        let edge = width / 2 + size / 2
        func added(_ span: Int) -> SIMD3<Double> {
            Self.linearMean(linear, width: width, columns: (edge + span)..<(edge + span + 3),
                            rows: (height / 2 - 2)..<(height / 2 + 2)) - SIMD3(repeating: surround)
        }
        let near = added(5)
        #expect(near.x > 0.01, "the light must light the frame outside itself (was \(near.x))")
        // Warm, in that order: red scatters furthest and responds to the least
        // light, blue to the most. A neutral or blue halo means the layers are
        // being fed each other's energy.
        #expect(near.x > near.y && near.y >= near.z,
                "the halo must be warm: r/g/b = \(near.x)/\(near.y)/\(near.z)")
        // Local: far from the light the frame returns to its own level, so this
        // is a halo and not a frame-wide lift.
        let far = added(400)
        #expect(abs(far.x) < 0.003 && abs(far.z) < 0.003,
                "the halo must not be frame-wide (added \(far.x)/\(far.z))")
    }

    /// Zero strength is identity when diffusion and exposure are also disabled.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func zeroStrengthIsIdentityForHalation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.blockSource(width: Self.side, height: Self.side,
                                      block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: Self.side, height: Self.side, sourcePixels: source,
            strength: 0, radiusFraction: 0.012, layerScale: Self.tint
        )
        // Decode-then-encode is not bit-exact in float16, so this compares in
        // code space with a tolerance of two half-float steps, not equality.
        for index in stride(from: 0, to: source.count, by: 4) {
            #expect(abs(Double(encoded[index]) - Double(source[index])) < 0.002,
                    "zero strength must not change the frame (index \\(index))")
        }
    }

    /// Exercise the production stage, not just its apply kernel: disabling both
    /// spatial effects must not bypass a requested push or pull.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func disabledSpatialEffectsStillApplyExposure() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let width = 9, height = 3
        let levels = [0.0, 0.02, 0.18, 0.75, 1.5, 2.25, 2.9, 3.0, 3.5]
        let source = Self.sourcePixels(width: width, height: height) { x, _ in
            SIMD3(levels[x], levels[(x + 1) % width], levels[(x + 2) % width])
        }
        let input = try Self.makeTexture(device: device, width: width, height: height, pixels: source)
        for stops in PushPullStops.allCases {
            let output = try #require(stage.applyHalation(
                source: input, commandQueue: queue, strength: 0, radiusFraction: 0.012,
                layerScale: Self.tint, diffusion: .disabled, highlightCeiling: 3,
                exposureStops: Float(stops.stops), width: width, height: height))
            let encoded = try Self.readBack(output, device: device, queue: queue, width: width, height: height)
            if stops == .none {
                #expect(output === input)
                #expect(encoded == source)
                continue
            }
            #expect(output !== input, "nonzero exposure must run the production stage")
            for index in encoded.indices where index % 4 != 3 {
                let expected = PushPullTransfer.gained(code: Double(source[index]), stops: stops, ceiling: 3)
                // Input is already quantized; allow one half-float output step.
                #expect(abs(Double(encoded[index]) - expected) < 0.001,
                        "stage exposure \(stops.displayName), channel index \(index)")
            }
            for index in stride(from: 3, to: encoded.count, by: 4) {
                #expect(encoded[index] == source[index])
            }
            let greyIndex = 2 * 4
            let changed = Double(encoded[greyIndex]) - Double(source[greyIndex])
            #expect(stops.isPull ? changed < -0.01 : changed > 0.01)
        }
        let unchanged = try Self.readBack(input, device: device, queue: queue, width: width, height: height)
        #expect(unchanged == source, "exposure must not mutate the source")
    }

    // MARK: - Per-layer physics

    /// Neutral sources across the knee ladder light exactly the layers whose
    /// knee they clear. Reading red's energy into the green/blue channels would
    /// light green and blue for a source that never reaches their knees.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationKneeLadderSelectsLayersByIntensity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        func halo(_ level: Double) throws -> SIMD3<Double> {
            let source = Self.blockSource(width: Self.side, height: Self.side,
                                          block: SIMD3(level, level, level))
            let encoded = try Self.runHalation(
                stage: stage, device: device, queue: queue,
                width: Self.side, height: Self.side, sourcePixels: source,
                // Neutral layer weights: this test is about which layer a level
                // clears, and the stock's red-dominant tint would mask a green or
                // blue response that is really there.
                strength: 1.0, radiusFraction: 0.03, layerScale: SIMD3(1, 1, 1)
            )
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            let band = Self.linearMean(linear, width: Self.side, columns: 160..<180, rows: 100..<156)
            return band - SIMD3(repeating: Self.surround)
        }

        // Sample against the stage's own onsets rather than literal levels: the
        // onsets are in stops above diffuse white and the mask reads the frame
        // through `frameWhiteStops`, so the level that clears a layer is
        // 2^(onset + frameWhite). Each level sits just under the NEXT layer's
        // onset, which keeps the cleared layer's mask (and so the measured
        // signal) as large as the window allows.
        let onsets = SpatialEffectsStage.halationOnsets()
        let frameWhite = SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0)
        func level(clearing onset: Float) -> Double { pow(2, Double(onset + frameWhite)) }
        // Above red, still under green.
        let redOnly = try halo(level(clearing: onsets.y) * 0.95)
        // Above green, still under blue.
        let redGreen = try halo(level(clearing: onsets.z) * 0.95)
        // Above all three.
        let allLayers = try halo(level(clearing: onsets.z) * 2.5)

        #expect(redOnly.x > 0.002, "red must respond above its knee (was \(redOnly.x))")
        #expect(redOnly.y < redOnly.x * 0.1, "green must stay dark below its knee (was \(redOnly.y))")
        #expect(redOnly.z < redOnly.x * 0.1, "blue must stay dark below its knee (was \(redOnly.z))")

        #expect(redGreen.y > 0.002, "green must respond above its knee (was \(redGreen.y))")
        #expect(redGreen.z < redGreen.y * 0.1, "blue must stay dark below its knee (was \(redGreen.z))")

        #expect(allLayers.z > 0.002, "blue must respond above its knee (was \(allLayers.z))")
    }

    /// Red responds from its earlier onset through a shaped low tail. Above the
    /// 4x-white join, the preserved linear-in-stops ramp still gives equal
    /// contributions for equal stop increments, independently of the new tail.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationStartsAtItsOnsetAndKeepsTheUpperRampLinear() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        func redAdded(_ level: Double) throws -> Double {
            let source = Self.blockSource(width: Self.side, height: Self.side,
                                          block: SIMD3(repeating: level))
            let encoded = try Self.runHalation(stage: stage, device: device, queue: queue,
                width: Self.side, height: Self.side, sourcePixels: source,
                strength: 1, radiusFraction: 0, layerScale: Self.tint)
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            // Compare against the quantized input, not the pre-encoding authored level.
            let input = Self.appleLogDecode(Double(source[(128 * Self.side + 128) * 4]))
            return Self.linearMean(linear, width: Self.side, columns: 120..<136, rows: 120..<136).x - input
        }
        let onset = Double(SpatialEffectsStage.halationOnsets().x)
        let frameWhite = Double(SpatialEffectsStage.frameWhiteStops(sceneLiftStops: 0))
        let reference = Double(SpatialEffectsStage.halationReferenceStops)
        // The mask level a source sits at, as the kernel reads it.
        func maskLevel(_ level: Double) -> Double {
            let stops = log2(level) - frameWhite
            let oldOnset = 0.6
            if stops >= 2 {
                return min(1, max(0, (stops - oldOnset) / (reference - oldOnset)))
            }
            let t = min(1, max(0, (stops - onset) / (2 - onset)))
            return (2 - oldOnset) / (reference - oldOnset) * pow(t, (2 - onset) / (2 - oldOnset))
        }

        #expect(abs(try redAdded(0.10)) < 0.002, "0.10 sits below the red onset")
        let justUnder = pow(2, onset + frameWhite) * 0.9
        #expect(abs(try redAdded(justUnder)) < 0.002, "just under the onset is still dark")
        for level in [1.25, 2, 3] {
            let added = try redAdded(level)
            #expect(added > 0.01, "red responds once it clears its onset (at \(level))")
            // The mask read back through the half-res texture is good to about a
            // twentieth of a stop, and the fraction is a share of the span, so the
            // tolerance is stated in stops: in fractions it would silently tighten
            // every time an onset rises and the span shortens.
            let tolerance = 0.06 / (reference - onset)
            #expect(abs(added - maskLevel(level)) < tolerance,
                    "the add is the mask fraction at \(level): \(added) vs \(maskLevel(level))")
        }
        // The earlier red tail is curved; equal-stop increments remain equal
        // on the preserved upper ramp, between the 4x join and 10x reference.
        let base = pow(2, 2 + frameWhite + 0.1)
        let step = pow(2, 0.25)
        let first = try redAdded(base * step) - redAdded(base)
        let second = try redAdded(base * step * step) - redAdded(base * step)
        // Stated in stops, like the fraction check above: the add is measured
        // through an encode/decode round trip, which compresses a fixed addition
        // slightly more in a brighter frame, so the evenness is good to a
        // twentieth of a stop rather than to the bit.
        #expect(abs(first - second) < 0.05 / (reference - 0.6),
                "equal upper-ramp stop increments must match: \(first) \(second)")
    }

    /// An all-red source exposes only the red layer, so its halo must stay red.
    /// If the apply kernel read `.r` from the green and blue diffusions, red's
    /// diffused energy would light them and the source would masquerade as RGB.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func colouredSourceDoesNotLightOtherLayers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        // Block: red at 3x diffuse white, green/blue at 18% grey. Only red is
        // above its knee, so the mask is (red, 0, 0).
        let source = Self.blockSource(
            width: Self.side, height: Self.side,
            block: SIMD3(Self.superwhite, Self.surround, Self.surround)
        )
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: Self.side, height: Self.side, sourcePixels: source,
            strength: 1.0, radiusFraction: 0.03, layerScale: Self.tint
        )
        let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
        let band = Self.linearMean(linear, width: Self.side, columns: 160..<180, rows: 100..<156)
        let added = band - SIMD3(repeating: Self.surround)

        #expect(added.x > 0.002, "the red layer must respond (was \\(added.x))")
        #expect(added.y < added.x * 0.1, "an all-red source must not light green (was \\(added.y))")
        #expect(added.z < added.x * 0.1, "an all-red source must not light blue (was \\(added.z))")
    }

    /// Per-stock halo geometry: two stocks with different radius and layer weight
    /// must produce measurably different spread AND colour.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func perStockGeometryChangesSpreadAndColour() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        func measure(radiusFraction: Float, layerScale: SIMD3<Float>) throws -> (far: SIMD3<Double>, near: SIMD3<Double>) {
            let source = Self.blockSource(width: Self.side, height: Self.side,
                                          block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
            let encoded = try Self.runHalation(
                stage: stage, device: device, queue: queue,
                width: Self.side, height: Self.side, sourcePixels: source,
                strength: 0.5, radiusFraction: radiusFraction, layerScale: layerScale
            )
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            // Far band, ~40-60px beyond the block's right edge (x=156).
            let far = Self.linearMean(linear, width: Self.side, columns: 196..<216, rows: 100..<156)
            // Band hugging the boundary, where both radii carry signal.
            let near = Self.linearMean(linear, width: Self.side, columns: 162..<182, rows: 100..<156)
            return (far, near)
        }

        let tight = try measure(radiusFraction: 0.008, layerScale: SIMD3(1.0, 0.20, 0.10))
        let wide = try measure(radiusFraction: 0.040, layerScale: SIMD3(1.0, 0.32, 0.10))

        let tightFar = tight.far.x - Self.surround
        let wideFar = wide.far.x - Self.surround
        #expect(wideFar > tightFar + 0.002,
                "wider per-stock radius must spread further (tight \\(tightFar), wide \\(wideFar))")

        let tightRatio = (tight.near.y - Self.surround) / (tight.near.x - Self.surround)
        let wideRatio = (wide.near.y - Self.surround) / (wide.near.x - Self.surround)
        #expect(wideRatio > tightRatio + 0.03,
                "per-stock layer weight must change halo colour (tight \\(tightRatio), wide \\(wideRatio))")
    }

    // MARK: - Radius: zero and small, without the old floor

    /// Zero radius means no spatial diffusion — but the scattered energy is
    /// still added, locally, over the source's own footprint. It is not "no
    /// effect", and it must not ask MPS for an invalid sigma of zero.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationZeroRadiusAddsLocalEnergyWithoutDiffusion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.blockSource(width: Self.side, height: Self.side,
                                      block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: Self.side, height: Self.side, sourcePixels: source,
            strength: 1.0, radiusFraction: 0, layerScale: Self.tint
        )
        let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)

        let core = Self.linearMean(linear, width: Self.side, columns: 110..<146, rows: 110..<146)
        let justOutside = Self.linearMean(linear, width: Self.side, columns: 158..<178, rows: 100..<156)
        let far = Self.linearMean(linear, width: Self.side, columns: 5..<40, rows: 5..<40)

        #expect(core.x - Self.superwhite > 0.002,
                "zero radius must still add local energy over the source (was \\(core.x - Self.superwhite))")
        #expect(justOutside.x - Self.surround < 0.003,
                "zero radius must not diffuse into the surround (was \\(justOutside.x - Self.surround))")
        #expect(abs(far.x - Self.surround) < 0.003, "zero radius must not reach the far field (was \\(far.x))")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func zeroStrengthPreservesEncodedShadowValuesExactly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.rawPixels(width: 8, height: 8) { _, _ in SIMD3(0.02, 0.1, 0.5) }
        let output = try Self.runHalation(stage: stage, device: device, queue: queue,
            width: 8, height: 8, sourcePixels: source, strength: 0, radiusFraction: 0.01,
            layerScale: Self.tint)
        #expect(output == source, "Disabled halation must not clamp negative scene-light noise or re-encode the source")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func zeroRadiusPreservesASinglePixelSourceFootprint() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let source = Self.sourcePixels(width: 8, height: 8) { x, y in
            x == 3 && y == 3 ? SIMD3(9, 9, 9) : SIMD3(0.18, 0.18, 0.18)
        }
        let output = try Self.runHalation(stage: stage, device: device, queue: queue,
            width: 8, height: 8, sourcePixels: source, strength: 1, radiusFraction: 0,
            layerScale: Self.tint)
        let changedPixels = (0..<64).filter { index in
            abs(Double(output[index * 4]) - Double(source[index * 4])) > 0.001
        }
        #expect(changedPixels == [27], "Zero radius must add energy only to the source pixel, not a resampled footprint")
    }

    /// A larger radius spreads further, and any positive radius spreads further
    /// than zero. This is what the removed `max(2, ...)` floor used to prevent:
    /// radii below two texels were silently clamped up to the same value.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationSmallRadiusSpreadsLessThanLarge() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        func band(radiusFraction: Float, columns: Range<Int>) throws -> Double {
            let source = Self.blockSource(width: Self.side, height: Self.side,
                                          block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
            let encoded = try Self.runHalation(
                stage: stage, device: device, queue: queue,
                width: Self.side, height: Self.side, sourcePixels: source,
                strength: 1.0, radiusFraction: radiusFraction, layerScale: Self.tint
            )
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            return Self.linearMean(linear, width: Self.side, columns: columns, rows: 100..<156).x - Self.surround
        }

        let nearWindow = 158..<178
        let farWindow = 196..<216

        let zero = try band(radiusFraction: 0, columns: nearWindow)
        let small = try band(radiusFraction: 0.01, columns: nearWindow)
        #expect(small > zero + 0.001,
                "any positive radius must spread further than zero (zero \(zero), small \(small))")

        // Reach, not peak: a coarse mip level averages a small source into its
        // texel, so the value hugging the block can be LOWER than a tight radius
        // even though the light travelled further. What the stage promises is
        // that a wider setting puts more light down the tail.
        let smallFar = try band(radiusFraction: 0.01, columns: farWindow)
        let largeFar = try band(radiusFraction: 0.03, columns: farWindow)
        #expect(largeFar > smallFar,
                "a larger radius must reach further (small \(smallFar), large \(largeFar))")
    }

    // MARK: - Accepted soft-step behaviour (full production stage)

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"),
          arguments: [0, 1, 2])
    func aColouredSourceOnlyScattersItsOwnChannel(channel: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let side = 128
        let source = Self.sourcePixels(width: side, height: side) { x, y in
            var rgb = SIMD3<Double>(repeating: 0.01)
            if (58..<70).contains(x), (58..<70).contains(y) {
                rgb[channel] = 6
            }
            return rgb
        }
        let result = try Self.runHalation(
            stage: stage, device: device, queue: queue, width: side, height: side,
            sourcePixels: source, strength: 1, radiusFraction: 0.02, layerScale: SIMD3(repeating: 1))
        let input = Self.decodedLinear(source, count: side * side)
        let output = Self.decodedLinear(result, count: side * side)
        let halo = Self.linearMean(output, width: side, columns: 71..<80, rows: 59..<69)
            - Self.linearMean(input, width: side, columns: 71..<80, rows: 59..<69)
        #expect(halo[channel] > 0.001, "the source channel must actually light its surroundings")
        for other in 0..<3 where other != channel {
            var maxLeak = 0.0
            for pixel in 0..<(side * side) {
                maxLeak = max(maxLeak, abs(output[pixel * 3 + other] - input[pixel * 3 + other]))
            }
            #expect(maxLeak < 0.0001,
                    "source channel \(channel) must not manufacture channel \(other): \(maxLeak)")
        }
    }

    /// The profile is measured in decoded light relative to the quantized input,
    /// not the unquantized fixture. Normalization separates reach from amplitude.
    private static func pointSpread(
        stage: SpatialEffectsStage, device: MTLDevice, queue: MTLCommandQueue,
        brightness: Double, growth: Float = 1, strength: Float = 1, radiusFraction: Float = 0.012,
        onsets: SIMD3<Float>? = nil
    ) throws -> SIMD3<Double> {
        let side = 256
        let source = sourcePixels(width: side, height: side) { x, y in
            SIMD3(repeating: (122..<134).contains(x) && (122..<134).contains(y) ? brightness : 0.01)
        }
        let result = try runHalation(
            stage: stage, device: device, queue: queue, width: side, height: side,
            sourcePixels: source, strength: strength, radiusFraction: radiusFraction,
            layerScale: SIMD3(repeating: 1), growth: growth, onsets: onsets)
        let input = decodedLinear(source, count: side * side)
        let output = decodedLinear(result, count: side * side)
        var energy = SIMD3<Double>(repeating: 0)
        var moment = SIMD3<Double>(repeating: 0)
        for y in 0..<side {
            for x in 0..<side {
                // Only the exterior halo: the source's own encode quantization
                // must not determine the measured spatial extent.
                if (122..<134).contains(x), (122..<134).contains(y) { continue }
                let dx = Double(x) - 127.5, dy = Double(y) - 127.5
                let distanceSquared = dx * dx + dy * dy
                for channel in 0..<3 {
                    let index = (y * side + x) * 3 + channel
                    let added = output[index] - input[index]
                    if added > 0.0001 {
                        energy[channel] += added
                        moment[channel] += added * distanceSquared
                    }
                }
            }
        }
        return SIMD3((moment.x / max(energy.x, 1e-9)).squareRoot(),
                     (moment.y / max(energy.y, 1e-9)).squareRoot(),
                     (moment.z / max(energy.z, 1e-9)).squareRoot())
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func brighterSourcesSendLightFurtherIntoDarkSurroundings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        // frameWhite=-1: these source levels are 2x/4x/8x diffuse white.
        let narrow = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: 0.5)
        let middle = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: 2)
        let wide = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: 4)
        let middleReference = try Self.pointSpread(
            stage: stage, device: device, queue: queue, brightness: 2,
            growth: 0, radiusFraction: 0.012 * 1.25)
        #expect(abs(middle.x / middleReference.x - 1) < 0.01,
                "at 4x white the middle bucket must have 1.25x the base radius")
        #expect(middle.x > narrow.x * 1.15)
        #expect(wide.x > middle.x * 1.10)
        let fixed = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: 4, growth: 0)
        let fixedLow = try Self.pointSpread(
            stage: stage, device: device, queue: queue, brightness: 1, growth: 0)
        #expect(abs(fixed.x / fixedLow.x - 1) < 0.03, "growth off must retain one brightness-independent shape")
        let dimmerGain = try Self.pointSpread(
            stage: stage, device: device, queue: queue, brightness: 4, strength: 0.5)
        #expect(abs(dimmerGain.x / wide.x - 1) < 0.03, "changing gain alone must not imitate radius growth")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func softStepKnotsDoNotPopBetweenWidths() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        for knot in [0.25, 2.0, 4.0, 6.0] { // source scene units: 0.5x/4x/8x/12x white
            let low = knot * 0.99, high = knot * 1.01
            #expect(Self.appleLogEncode(low) != Self.appleLogEncode(high),
                    "the quantized inputs must actually straddle the knot")
            let below = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: low, onsets: SIMD3(repeating: -2))
            let above = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: high, onsets: SIMD3(repeating: -2))
            #expect(abs(above.x / below.x - 1) < 0.04,
                    "a small exposure change at a knot must not jump to another width")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func earlySmallAndFourthRadiiMatchTheirGaussianReferences() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        // Neutralize energy onsets only for this width fixture so the first
        // 0.5x-white anchor actually carries measurable light. Production onsets
        // are unchanged, and the separate knee/channel tests retain them.
        let onsets = SIMD3<Float>(repeating: -2)
        for (brightness, factor) in [(0.25, Float(0.5)), (2.0, Float(1.25)),
                                      (4.0, Float(2)), (6.0, Float(2.5))] {
            let actual = try Self.pointSpread(stage: stage, device: device, queue: queue,
                                              brightness: brightness, onsets: onsets)
            let reference = try Self.pointSpread(stage: stage, device: device, queue: queue,
                                                 brightness: brightness, growth: 0,
                                                 radiusFraction: 0.012 * factor, onsets: onsets)
            #expect(abs(actual.x / reference.x - 1) < 0.01,
                    "brightness \(brightness * 2)x white must use radius factor \(factor)")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func redHaloReachesFurtherThanGreenAndBlue() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        // All layers saturate: equal tint removes onset/amplitude as explanations.
        let spread = try Self.pointSpread(stage: stage, device: device, queue: queue, brightness: 6)
        #expect(spread.x > spread.y * 1.3, "red must have a genuinely wider spatial profile")
        #expect(spread.y > spread.z * 1.3, "green must be wider than blue")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func diagonalHaloHasNoCoarseGridStaircase() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let side = 256
        let source = Self.sourcePixels(width: side, height: side) { x, y in
            SIMD3(repeating: x < y ? 6 : 0.01)
        }
        let result = try Self.runHalation(
            stage: stage, device: device, queue: queue, width: side, height: side,
            sourcePixels: source, strength: 1, radiusFraction: 0.012, layerScale: SIMD3(repeating: 1))
        let input = Self.decodedLinear(source, count: side * side)
        let output = Self.decodedLinear(result, count: side * side)
        var offsets: [Double] = []
        for y in 64..<160 {
            for x in (y + 1)..<min(side - 1, y + 90) {
                let i = (y * side + x) * 3
                let a = output[i] - input[i], b = output[i + 3] - input[i + 3]
                if a >= 0.1, b < 0.1 {
                    offsets.append(Double(x - y) + (a - 0.1) / (a - b))
                    break
                }
            }
        }
        #expect(offsets.count == 96, "every interior scanline must cross the exterior halo contour")
        let mean = offsets.reduce(0, +) / Double(max(offsets.count, 1))
        let rms = (offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                   / Double(max(offsets.count, 1))).squareRoot()
        #expect(rms < 0.6, "a straight light edge must have a straight halo contour, rms \(rms) px")
    }

    // MARK: - Apply kernel (dispatched directly)

    /// Compile `spatial_halation_apply` on its own, so a test can hand it an
    /// authored mask and read the encoded result back without the stage's
    /// prepare pass or its lens diffusion ladder.
    private static func halationApplyPipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let function = try #require(
            try shaderLibrary(device: device).makeFunction(name: "spatial_halation_apply")
        )
        return try device.makeComputePipelineState(function: function)
    }

    /// Uniform rgba pixels for one mask level.
    private static func uniformPixels(
        width: Int, height: Int, _ value: SIMD3<Float>
    ) -> [Float16] {
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = Float16(value.x)
            pixels[index * 4 + 1] = Float16(value.y)
            pixels[index * 4 + 2] = Float16(value.z)
            pixels[index * 4 + 3] = 1
        }
        return pixels
    }

    /// An authored unfiltered mask for exact linear-composite arithmetic.
    private static func makeMask(
        device: MTLDevice, width: Int, height: Int, levels: [[Float16]]
    ) throws -> MTLTexture {
        #expect(levels.count == 1)
        return try makeTexture(device: device, width: width, height: height,
                               pixels: try #require(levels.first))
    }

    /// Dispatch `spatial_halation_apply` with four bucket texture slots and
    /// return the encoded frame.
    ///
    /// The lens diffusion node is pinned OFF — zero weights, zero amount — so
    /// the ladder slots 5-8 are never sampled; the mask is bound there anyway so
    /// no slot is left dangling. Every constant buffer is set explicitly,
    /// including the ones this harness does not exercise, because an unbound
    /// `constant float&` reads undefined memory.
    private static func applyHalationDirectly(
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int,
        source: [Float16],
        mask: MTLTexture,
        strength: Float = 1,
        layerScale: SIMD3<Float> = SIMD3(1, 1, 1),
        middle: MTLTexture? = nil,
        wide: MTLTexture? = nil,
        fourth: MTLTexture? = nil,
        bucketWeight: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    ) throws -> [Float16] {
        let sourceTexture = try makeTexture(
            device: device, width: width, height: height, pixels: source
        )
        let output = try makeTexture(
            device: device, width: width, height: height,
            pixels: [Float16](repeating: 0, count: width * height * 4)
        )
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(mask, index: 1)
        encoder.setTexture(middle ?? mask, index: 2)
        encoder.setTexture(wide ?? mask, index: 3)
        encoder.setTexture(fourth ?? mask, index: 9)
        encoder.setTexture(output, index: 4)
        for index in 5...8 {
            encoder.setTexture(mask, index: index)
        }

        var strength = strength
        var layerScale = layerScale
        var diffusionWeights = SIMD4<Float>(0, 0, 0, 0)
        var diffusionAmount: Float = 0
        // Neutral exposure and no transport leak: this harness pins the mask's
        // bucket arithmetic, not the develop lift or the burn.
        var exposureStops: Float = 0
        var exposureCeiling: Float = 1
        var postEmulsionStops: Float = 0
        var leakStops: Float = 0
        var leakTint = SIMD3<Float>(0, 0, 0)
        var leakEdgeShare: Float = 0
        var leakEdgeFalloff: Float = 0.2
        var leakSlip: Float = 0
        var bucketWeight = bucketWeight

        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
        encoder.setBytes(&diffusionWeights, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.setBytes(&diffusionAmount, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&exposureStops, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&exposureCeiling, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(&postEmulsionStops, length: MemoryLayout<Float>.size, index: 6)
        encoder.setBytes(&leakStops, length: MemoryLayout<Float>.size, index: 7)
        encoder.setBytes(&leakTint, length: MemoryLayout<SIMD3<Float>>.size, index: 8)
        encoder.setBytes(&leakEdgeShare, length: MemoryLayout<Float>.size, index: 9)
        encoder.setBytes(&leakEdgeFalloff, length: MemoryLayout<Float>.size, index: 10)
        encoder.setBytes(&leakSlip, length: MemoryLayout<Float>.size, index: 11)
        encoder.setBytes(&bucketWeight, length: MemoryLayout<SIMD4<Float>>.size, index: 12)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return try readBack(output, device: device, queue: queue, width: width, height: height)
    }

    /// Without filtering, the unsplit mask is added exactly once, even though
    /// it is bound in all three slots. This is the zero-radius contract.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationApplyPassesUnsplitEnergyStraightThrough() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pipeline = try Self.halationApplyPipeline(device: device)
        let side = 16
        let base: Double = 0.18
        let source = Self.sourcePixels(width: side, height: side) { _, _ in
            SIMD3(base, base, base)
        }
        let mask = try Self.makeMask(
            device: device, width: side, height: side,
            levels: [Self.uniformPixels(width: side, height: side, SIMD3(0.2, 0.1, 0.05))]
        )

        func added() throws -> SIMD3<Double> {
            let encoded = try Self.applyHalationDirectly(
                device: device, queue: queue, pipeline: pipeline,
                width: side, height: side, source: source, mask: mask)
            return SIMD3(
                Self.appleLogDecode(Double(encoded[0])),
                Self.appleLogDecode(Double(encoded[1])),
                Self.appleLogDecode(Double(encoded[2]))
            ) - SIMD3(base, base, base)
        }

        let flat = try added()
        #expect(abs(flat.x - 0.2) < 0.004,
                "a mask with no chain adds its own red (was \(flat.x))")
        #expect(abs(flat.y - 0.1) < 0.004,
                "a mask with no chain adds its own green (was \(flat.y))")
        #expect(abs(flat.z - 0.05) < 0.004,
                "a mask with no chain adds its own blue (was \(flat.z))")

    }

    /// Each filtered bucket contributes its own RGB energy, once, in linear light.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationApplySumsFilteredBucketsWithoutMixingChannels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pipeline = try Self.halationApplyPipeline(device: device)
        let side = 8
        let source = Self.sourcePixels(width: side, height: side) { _, _ in SIMD3(repeating: 0.18) }
        func bucket(_ rgb: SIMD3<Float>) throws -> MTLTexture {
            try Self.makeTexture(device: device, width: side, height: side,
                                 pixels: Self.uniformPixels(width: side, height: side, rgb))
        }
        let narrow = try bucket(SIMD3(0.2, 0.01, 0.02))
        let middle = try bucket(SIMD3(0.03, 0.1, 0.04))
        let wide = try bucket(SIMD3(0.05, 0.06, 0.3))
        let fourth = try bucket(SIMD3(0.07, 0.08, 0.09))
        let encoded = try Self.applyHalationDirectly(
            device: device, queue: queue, pipeline: pipeline,
            width: side, height: side, source: source, mask: narrow,
            middle: middle, wide: wide, fourth: fourth, bucketWeight: SIMD4(repeating: 1))
        let output = Self.decodedLinear(encoded, count: side * side)
        // Base 0.18 plus the corresponding channel from all FOUR buckets.
        for (channel, expected) in [0.53, 0.43, 0.63].enumerated() {
            #expect(abs(output[channel] - expected) < 0.004,
                    "bucket sum must preserve channel \(channel)")
        }
    }

    /// The scattered energy is added in scene-LINEAR light and then re-encoded to
    /// Apple Log 2, so the stock LUT grades it by the same curve as the source.
    ///
    /// Dispatches `spatial_halation_apply` directly with a uniform source and a
    /// known mask so the arithmetic is exact. A kernel that added in the encoded
    /// (code) domain instead — the old bug — would land near 0.95, not 0.38, so
    /// the two orders are far apart.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationEnergyIsAddedInSceneLinearBeforeTheEncode() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let pipeline = try Self.halationApplyPipeline(device: device)
        let side = 16
        let base: Double = 0.18
        let source = Self.sourcePixels(width: side, height: side) { _, _ in
            SIMD3(base, base, base)
        }
        // A mask fraction of 0.2 on a non-mipmapped mask: it is added as-is.
        let mask = try Self.makeMask(
            device: device, width: side, height: side,
            levels: [Self.uniformPixels(width: side, height: side, SIMD3(0.2, 0.2, 0.2))]
        )

        func added(strength: Float) throws -> SIMD3<Double> {
            let encoded = try Self.applyHalationDirectly(
                device: device, queue: queue, pipeline: pipeline,
                width: side, height: side, source: source, mask: mask,
                strength: strength)
            return SIMD3(
                Self.appleLogDecode(Double(encoded[0])),
                Self.appleLogDecode(Double(encoded[1])),
                Self.appleLogDecode(Double(encoded[2]))
            )
        }

        let full = try added(strength: 1.0)
        #expect(abs(full.x - 0.38) < 0.004, "linear add + encode expected 0.38 (was \(full.x))")
        #expect(abs(full.y - 0.38) < 0.004, "linear add + encode expected 0.38 (was \(full.y))")
        #expect(abs(full.z - 0.38) < 0.004, "linear add + encode expected 0.38 (was \(full.z))")

        let half = try added(strength: 0.5)
        #expect(abs(half.x - 0.28) < 0.004, "strength must scale the linear contribution (was \(half.x))")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func sourceBrightnessBucketsConserveEveryChannel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        for level in [1.0, 2.0, 3.0, 4.0, 6.0, 8.0, 10.0, 12.0] {
            func mask(_ bucket: Int?) throws -> [Float16] {
                try Self.halationMask(device: device, queue: queue,
                                      width: 2, height: 2, maskWidth: 1, maskHeight: 1, bucket: bucket) { _, _ in
                    SIMD3(repeating: level)
                }
            }
            let unsplit = try mask(nil)
            let narrow = try mask(0), middle = try mask(1), wide = try mask(2), fourth = try mask(3)
            for channel in 0..<3 {
                let sum = Double(narrow[channel]) + Double(middle[channel]) + Double(wide[channel]) + Double(fourth[channel])
                #expect(abs(sum - Double(unsplit[channel])) < 0.002,
                        "source split must conserve channel \(channel) at \(level)x")
            }
            if level == 1 {
                #expect(abs(Double(narrow[0]) - Double(unsplit[0])) < 0.002)
                #expect(Double(middle[0]) < 0.002 && Double(wide[0]) < 0.002)
            } else if level == 4 {
                // Source and mask are float16: an encoded knot can decode just
                // either side, so require an almost-complete handoff, not bit equality.
                #expect(abs(Double(middle[0]) - Double(unsplit[0])) < 0.002)
                #expect(Double(narrow[0]) < 0.002 && Double(wide[0]) < 0.002)
            } else if level == 8 {
                #expect(abs(Double(wide[0]) - Double(unsplit[0])) < 0.002)
                #expect(Double(narrow[0]) < 0.002 && Double(middle[0]) < 0.002)
                #expect(Double(fourth[0]) < 0.002)
            } else if level >= 12 {
                #expect(abs(Double(fourth[0]) - Double(unsplit[0])) < 0.002)
                #expect(Double(narrow[0]) < 0.002 && Double(middle[0]) < 0.002 && Double(wide[0]) < 0.002)
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func earlyRedBeginsAtHalfWhiteAndSmoothlyRejoinsAtFour() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let onsets = SpatialEffectsStage.authoredOnsets
        let reference = SpatialEffectsStage.halationReferenceStops
        #expect(abs(exp2(Double(onsets.x)) - 0.5) < 0.0001)
        let levels = [0.4, 0.5, 0.55, 0.75, 1, 1.5, 2, pow(2, 1.9), 4, pow(2, 2.1), 8, 10, 12]
        let mask = try Self.halationMask(
            device: device, queue: queue, width: levels.count * 2, height: 2,
            maskWidth: levels.count, maskHeight: 1, onsets: onsets, reference: reference
        ) { x, _ in SIMD3(repeating: levels[x / 2]) }
        func red(_ index: Int) -> Double { Double(mask[index * 4]) }
        #expect(red(0) < 0.001 && red(1) < 0.001)
        // Independent numerical pins: a narrow, nonzero low-light red tail,
        // not a globally shifted linear ramp that also brightens the midpoint.
        for (index, expected) in [(3, 0.0154825), (4, 0.0488487), (6, 0.2157334)] {
            #expect(abs(red(index) - expected) < 0.002)
        }
        for index in 1..<levels.count {
            #expect(red(index) >= red(index - 1) - 0.001)
        }
        for index in [8, 9, 10, 11, 12] {
            let old = min(1, max(0, (log2(levels[index]) - 0.6) / (Double(reference) - 0.6)))
            #expect(abs(red(index) - old) < 0.002, "4x and brighter must retain the previous red response")
        }
        let leftSlope = (red(8) - red(7)) / 0.1
        let rightSlope = (red(9) - red(8)) / 0.1
        #expect(abs(leftSlope - rightSlope) < 0.03, "the join must not introduce a slope kink")
        for index in levels.indices {
            for channel in 1...2 {
                let onset = Double(onsets[channel])
                let expected = min(1, max(0, (log2(levels[index]) - onset) / (Double(reference) - onset)))
                #expect(abs(Double(mask[index * 4 + channel]) - expected) < 0.002,
                        "green/blue response must remain unchanged")
            }
        }
    }

    // MARK: - Mask kernel (dispatched directly)

    /// Dispatch `spatial_halation_mask` directly and read the half-resolution
    /// mask back, so per-layer energy and the 2x2 downsample can be asserted
    /// exactly instead of inferred through the Gaussian filters and composite.
    private static func halationMask(
        device: MTLDevice,
        queue: MTLCommandQueue,
        width: Int,
        height: Int,
        maskWidth: Int,
        maskHeight: Int,
        bucket: Int? = nil,
        onsets: SIMD3<Float> = SIMD3(0.6, 1, 2), reference: Float = 3,
        linear: (Int, Int) -> SIMD3<Double>
    ) throws -> [Float16] {
        let function = try #require(
            try shaderLibrary(device: device).makeFunction(name: "spatial_halation_mask")
        )
        let pipeline = try device.makeComputePipelineState(function: function)

        let input = try makeTexture(
            device: device, width: width, height: height,
            pixels: sourcePixels(width: width, height: height, linear)
        )
        func emptyMask() throws -> MTLTexture {
            try makeTexture(device: device, width: maskWidth, height: maskHeight,
                            pixels: [Float16](repeating: 0, count: maskWidth * maskHeight * 4))
        }
        let mask = try emptyMask()
        let middle = try emptyMask()
        let wide = try emptyMask()
        let fourth = try emptyMask()
        let buckets = [mask, middle, wide, fourth]

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var redOnset = onsets.x
        var greenOnset = onsets.y
        var blueOnset = onsets.z
        // Onsets in stops above diffuse white, and the frame's own offset at zero
        // so t = log2(linear) exactly. The default decoder fixture keeps the
        // legacy linear red branch; response tests pass production onsets explicitly.
        var referenceStops = reference
        var frameWhite: Float = 0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(mask, index: 1)
        encoder.setTexture(middle, index: 2)
        encoder.setTexture(wide, index: 3)
        encoder.setTexture(fourth, index: 5)
        var exposure: Float = 0
        var ceiling: Float = 12
        var split: UInt32 = bucket == nil ? 0 : 1
        encoder.setBytes(&exposure, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&ceiling, length: MemoryLayout<Float>.size, index: 4)
        encoder.setBytes(&split, length: MemoryLayout<UInt32>.size, index: 7)
        encoder.setBytes(&redOnset, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&greenOnset, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&blueOnset, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&referenceStops, length: MemoryLayout<Float>.size, index: 5)
        encoder.setBytes(&frameWhite, length: MemoryLayout<Float>.size, index: 6)
        encoder.dispatchThreadgroups(
            MTLSize(width: (maskWidth + 15) / 16, height: (maskHeight + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        return try readBack(buckets[bucket ?? 0], device: device, queue: queue, width: maskWidth, height: maskHeight)
    }

    /// A subpixel superwhite must survive the half-resolution downsample.
    ///
    /// One 9x pixel in a 2x2 block with three 18% pixels averages to
    /// (9 + 3*0.18) / 4 = 2.385 of diffuse white, so all three layers see a level
    /// above red's onset and two of them clear green's. Averaging the ENCODED
    /// values and decoding once instead collapses that to ~0.49 — below red's own
    /// onset — so the specular would vanish entirely. The two outcomes are far
    /// apart, so this pins the decode-before-average order.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationMaskDecodesEachSampleBeforeAveraging() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())

        let mask = try Self.halationMask(
            device: device, queue: queue, width: 4, height: 4, maskWidth: 2, maskHeight: 2
        ) { column, row in
            (column == 0 && row == 0) ? SIMD3(9.0, 9.0, 9.0) : SIMD3(0.18, 0.18, 0.18)
        }

        // Mask texel (0,0) covers source pixels (0,0),(1,0),(0,1),(1,1), so the
        // block sits at t = log2(2.385) = 1.254 stops above white.
        let red = Double(mask[0])
        let green = Double(mask[1])
        let blue = Double(mask[2])
        #expect(abs(red - (1.254 - 0.6) / 2.4) < 0.02,
                "red must preserve the subpixel specular (was \(red))")
        #expect(abs(green - (1.254 - 1.0) / 2.0) < 0.02,
                "green must respond to the specular from its own onset (was \(green))")
        #expect(red > green, "the lower onset carries the larger fraction at one level")
        #expect(blue < 0.01, "blue is below its 2-stop onset and must stay dark (was \(blue))")
    }

    /// A mask texel whose 2x2 block runs off an odd-sized frame must average the
    /// samples that exist, not always divide by four. Halving a partial block's
    /// level can drop it below an onset and erase the highlight there.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationMaskAveragesOnlyValidPixelsForOddDimensions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())

        // 3x2 source into a 2x1 mask: the second mask texel covers source
        // columns 2 and 3, but column 3 does not exist, so only 2 samples are
        // valid. A uniform 2.5x-white source (t = 1.322 stops) makes the expected
        // fractions exact regardless of how many samples land.
        let mask = try Self.halationMask(
            device: device, queue: queue, width: 3, height: 2, maskWidth: 2, maskHeight: 1
        ) { _, _ in SIMD3(2.5, 2.5, 2.5) }

        // Texel (1,0): partial block, must equal the full-block value.
        let red = Double(mask[4])
        let green = Double(mask[5])
        let blue = Double(mask[6])
        #expect(abs(red - (1.322 - 0.6) / 2.4) < 0.02,
                "partial block must average its valid samples (was \(red))")
        #expect(abs(green - 0.322 / 2.0) < 0.02,
                "partial block must average its valid samples (was \(green))")
        #expect(blue < 0.01, "blue is below its 2-stop onset (was \(blue))")

        // Texel (0,0): full block, same uniform source, must agree.
        #expect(abs(Double(mask[0]) - red) < 0.02,
                "full and partial blocks of a uniform source must agree")
    }

    // MARK: - Profiles and glow

    /// The outward halo is a single connected, monotonically decaying,
    /// light-only ramp. No detached lobe (the old sparse-tap kernel left them)
    /// and no dark gap; the profile never recovers after falling.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationProfileIsConnectedMonotonicAndLightOnly() throws {
        let side = 1024
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        // A thin vertical line: two half-res mask texels, symmetric about centre.
        let source = Self.sourcePixels(width: side, height: side) { column, _ in
            (510..<514).contains(column)
                ? SIMD3(Self.superwhite, Self.superwhite, Self.superwhite)
                : SIMD3(Self.surround, Self.surround, Self.surround)
        }
        let encoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: side, height: side, sourcePixels: source,
            strength: 2.0, radiusFraction: 0.012, layerScale: Self.tint
        )
        let linear = Self.decodedLinear(encoded, count: side * side)

        let row = 512
        func red(_ column: Int) -> Double { linear[(row * side + column) * 3] }
        func encodedRed(_ column: Int) -> Double { Double(encoded[(row * side + column) * 4]) }

        // Light-only: scattered energy is added, never subtracted, so the profile
        // never dips below the source level.
        var minimum = Double.greatestFiniteMagnitude
        var largestRecovery = 0.0
        var lowestSoFar = encodedRed(514)
        var largestAsymmetry = 0.0
        for distance in 0..<320 {
            let right = encodedRed(514 + distance)
            let left = encodedRed(509 - distance)
            minimum = min(minimum, red(514 + distance))
            largestRecovery = max(largestRecovery, right - lowestSoFar)
            lowestSoFar = min(lowestSoFar, right)
            largestAsymmetry = max(largestAsymmetry, abs(right - left))
        }
        #expect(minimum >= Self.surround - 0.003, "the halo must be light-only (min \\(minimum))")
        // Two half-float steps allow readback/approximation noise, not ghost lobes.
        #expect(largestRecovery <= 0.002,
                "the outward tail must not recover after falling (recovery \\(largestRecovery))")
        #expect(largestAsymmetry <= 0.003, "diffusion must remain symmetric about the thin highlight")

        // Connectivity: the lit part of the tail has no dark gaps. A 4px line
        // diffused at this radius carries its strongest tail within ~48px.
        let minimumTail = (0..<48).map { red(514 + $0) }.min()!
        #expect(minimumTail > Self.surround + 0.001, "the tail must be continuously lit (min \\(minimumTail))")
        // Decay: the tail falls away rather than lifting the whole frame.
        #expect(red(514) > red(514 + 300) + 0.001, "the tail must decay rather than lifting the frame")
    }

    /// Glow is a broad, post-LUT bloom that reaches further than the tight halo.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func glowIsABroadBloomReachingFurtherThanHalation() throws {
        let side = 1024
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        // Halation reach, measured in scene-linear added light on the source.
        let source = Self.sourcePixels(width: side, height: side) { column, _ in
            (510..<514).contains(column)
                ? SIMD3(Self.superwhite, Self.superwhite, Self.superwhite)
                : SIMD3(Self.surround, Self.surround, Self.surround)
        }
        let halationEncoded = try Self.runHalation(
            stage: stage, device: device, queue: queue,
            width: side, height: side, sourcePixels: source,
            strength: 1.0, radiusFraction: 0.012, layerScale: Self.tint
        )
        let halationLinear = Self.decodedLinear(halationEncoded, count: side * side)
        var halationReach = 0
        for distance in 0..<500 where halationLinear[(512 * side + 514 + distance) * 3] - Self.surround > 0.001 {
            halationReach = distance
        }

        // Glow reach, measured on the graded image it blooms.
        let gradedPixels = Self.rawPixels(width: side, height: side) { column, _ in
            (510..<514).contains(column) ? SIMD3(1.0, 1.0, 1.0) : SIMD3(0.125, 0.125, 0.125)
        }
        let graded = try Self.makeTexture(device: device, width: side, height: side, pixels: gradedPixels)
        let glowed = try #require(stage.applyGlow(
            graded: graded, commandQueue: queue, strength: 0.75, width: side, height: side
        ))
        let glowValues = try Self.readBack(glowed, device: device, queue: queue, width: side, height: side)
        func glowRed(_ column: Int) -> Double { Double(glowValues[(512 * side + column) * 4]) }
        var glowReach = 0
        for distance in 0..<500 where glowRed(514 + distance) - 0.125 > 0.001 {
            glowReach = distance
        }

        #expect(halationReach > 0, "halation must reach beyond the source")
        #expect(glowReach > halationReach,
                "glow must reach further than halation (halation \\(halationReach), glow \\(glowReach))")
    }

    /// Glow is unchanged by the halation work: zero strength is a passthrough.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func zeroStrengthIsIdentityForGlow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let pixels = Self.rawPixels(width: Self.side, height: Self.side) { column, row in
            let inBlock = column >= Self.blockLower && column < Self.blockUpper
                && row >= Self.blockLower && row < Self.blockUpper
            return SIMD3(repeating: inBlock ? 0.8 : 0.05)
        }
        let graded = try Self.makeTexture(device: device, width: Self.side, height: Self.side, pixels: pixels)
        let glowed = try #require(stage.applyGlow(
            graded: graded, commandQueue: queue, strength: 0, width: Self.side, height: Self.side
        ))
        let values = try Self.readBack(glowed, device: device, queue: queue, width: Self.side, height: Self.side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            #expect(abs(Double(values[index]) - Double(pixels[index])) < 0.002,
                    "zero glow strength must not change the frame (index \\(index))")
        }
    }

    /// A video take is locked to its shutter, so a bright day is pulled down in
    /// the render. That pull must land BEFORE the emulsion: applied after
    /// halation, the frame came back darker carrying the halo of the light the
    /// sensor saw — the opposite of a workable result in unsuitable conditions.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func aPullDarkensTheHaloWithTheFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let width = 64, height = 64
        let base: Double = 0.18
        let source = Self.sourcePixels(width: width, height: height) { x, y in
            let hot = (20..<24).contains(x) && (20..<24).contains(y)
            return hot ? SIMD3(12, 12, 12) : SIMD3(base, base, base)
        }

        func measure(stops: Float) throws -> (mean: Double, halo: Double) {
            let input = try Self.makeTexture(device: device, width: width, height: height,
                                             pixels: source)
            let output = try #require(stage.applyHalation(
                source: input, commandQueue: queue, strength: 2.52, radiusFraction: 0.02,
                layerScale: SIMD3(1, 0.32, 0.1), exposureStops: stops,
                width: width, height: height))
            let linear = Self.decodedLinear(
                try Self.readBack(output, device: device, queue: queue, width: width, height: height),
                count: width * height)
            var total = 0.0, ring = 0.0
            var ringCount = 0
            for y in 0..<height {
                for x in 0..<width {
                    let red = linear[(y * width + x) * 3]
                    total += red
                    let dx = Double(x) - 21.5, dy = Double(y) - 21.5
                    let radius = (dx * dx + dy * dy).squareRoot()
                    if radius > 5, radius < 11 {
                        ring += red
                        ringCount += 1
                    }
                }
            }
            return (total / Double(width * height), ring / Double(max(ringCount, 1)))
        }

        let none = try measure(stops: 0)
        let pulled = try measure(stops: -2)

        // The frame itself is two stops darker.
        #expect(pulled.mean < none.mean * 0.5,
                "a -2 pull must darken the frame: \(pulled.mean) vs \(none.mean)")
        // And the halo is pulled with it, rather than staying at the exposure the
        // sensor saw. The ring carries some of the field, so compare the excess.
        let excessNone = none.halo - base
        let excessPulled = pulled.halo - base
        #expect(excessPulled < excessNone * 0.6,
                "the halo must follow the pull: \(excessPulled) vs \(excessNone)")
    }
}
