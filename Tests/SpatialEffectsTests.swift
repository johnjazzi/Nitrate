import Foundation
import Testing
import Metal
import simd

/// Behavioural tests for the spatial halation/glow stage (epic story 1.4).
///
/// The stage now has TWO independent halves, and the tests are split the same
/// way:
///
///  * `applyHalation` is physical and PRE-LUT. It decodes the ungraded Apple Log
///    2 frame to linear scene light, diffuses each emulsion layer's superwhite
///    excess at its own radius, adds the scattered energy back in LINEAR light,
///    and re-encodes to Apple Log 2. The properties pinned here are the ones
///    that make that physical: light appears OUTSIDE the source, the added light
///    is warm, it is LOCAL, zero strength is identity, the source core grows
///    instead of being hollowed into a ring, the per-layer knees select layers by
///    intensity, each layer's own channel is read, and the whole thing is added
///    in scene-linear BEFORE the encode.
///
///  * `applyGlow` is a post-LUT graded-luminance bloom, unchanged in look. Its
///    tests pin that it still spreads light broadly and further than halation.
///
/// The mask kernel `spatial_halation_mask` is also dispatched directly so its
/// decode-before-average order and odd-dimension handling can be asserted
/// exactly rather than inferred through the blur and composite.
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
        strength: Float, radiusFraction: Float, layerScale: SIMD3<Float>
    ) throws -> [Float16] {
        let input = try makeTexture(device: device, width: width, height: height, pixels: sourcePixels)
        let output = try #require(stage.applyHalation(
            source: input, commandQueue: queue,
            strength: strength, radiusFraction: radiusFraction, layerScale: layerScale,
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

    /// Compile `Resources/Shaders/spatial.metal` at runtime so the test exercises
    /// the shader that actually ships.
    private static func shaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let shaderURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Resources/Shaders/spatial.metal")
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
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

    /// Zero strength is identity: a stock with halation at 0 is a passthrough.
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
                strength: 1.0, radiusFraction: 0.03, layerScale: Self.tint
            )
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            let band = Self.linearMean(linear, width: Self.side, columns: 160..<180, rows: 100..<156)
            return band - SIMD3(repeating: Self.surround)
        }

        // 1.5x: clears red's 1.0 knee only.
        let redOnly = try halo(1.5)
        // 3.0x: clears red and green, still below blue's 4.0.
        let redGreen = try halo(3.0)
        // 8.0x: clears all three.
        let allLayers = try halo(8.0)

        #expect(redOnly.x > 0.002, "red must respond above its 1.0 knee (was \\(redOnly.x))")
        #expect(redOnly.y < redOnly.x * 0.1, "green must stay dark below its 2.0 knee (was \\(redOnly.y))")
        #expect(redOnly.z < redOnly.x * 0.1, "blue must stay dark below its 4.0 knee (was \\(redOnly.z))")

        #expect(redGreen.y > 0.002, "green must respond above its 2.0 knee (was \\(redGreen.y))")
        #expect(redGreen.z < redGreen.y * 0.1, "blue must stay dark below its 4.0 knee (was \\(redGreen.z))")

        #expect(allLayers.z > 0.002, "blue must respond above its 4.0 knee (was \\(allLayers.z))")
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

        func nearBand(radiusFraction: Float) throws -> Double {
            let source = Self.blockSource(width: Self.side, height: Self.side,
                                          block: SIMD3(Self.superwhite, Self.superwhite, Self.superwhite))
            let encoded = try Self.runHalation(
                stage: stage, device: device, queue: queue,
                width: Self.side, height: Self.side, sourcePixels: source,
                strength: 1.0, radiusFraction: radiusFraction, layerScale: Self.tint
            )
            let linear = Self.decodedLinear(encoded, count: Self.side * Self.side)
            return Self.linearMean(linear, width: Self.side, columns: 158..<178, rows: 100..<156).x - Self.surround
        }

        let zero = try nearBand(radiusFraction: 0)
        let small = try nearBand(radiusFraction: 0.01)
        let large = try nearBand(radiusFraction: 0.03)

        #expect(small > zero + 0.001, "any positive radius must spread further than zero (zero \\(zero), small \\(small))")
        #expect(large > small + 0.001, "a larger radius must spread further (small \\(small), large \\(large))")
    }

    // MARK: - Order of operations

    /// The scattered energy is added in scene-LINEAR light and then re-encoded to
    /// Apple Log 2, so the stock LUT grades it by the same curve as the source.
    ///
    /// Dispatches `spatial_halation_apply` directly with a uniform source and
    /// known diffusion so the arithmetic is exact. A kernel that added in the
    /// encoded (code) domain instead — the old bug — would land near 0.95, not
    /// 0.38, so the two orders are far apart.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationEnergyIsAddedInSceneLinearBeforeTheEncode() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let function = try #require(
            try Self.shaderLibrary(device: device).makeFunction(name: "spatial_halation_apply")
        )
        let pipeline = try device.makeComputePipelineState(function: function)
        let side = 16

        // Source 0.18; each layer carries 1.6, normalized by referenceSuperwhite
        // 8 → 0.2 added in linear → 0.38.
        let source = Self.sourcePixels(width: side, height: side) { _, _ in SIMD3(0.18, 0.18, 0.18) }
        func fill(_ channel: Int, _ value: Float) -> [Float16] {
            var pixels = [Float16](repeating: 0, count: side * side * 4)
            for index in 0..<(side * side) { pixels[index * 4 + channel] = Float16(value) }
            return pixels
        }

        func run(strength: Float) throws -> SIMD3<Double> {
            let sourceTexture = try Self.makeTexture(device: device, width: side, height: side, pixels: source)
            let red = try Self.makeTexture(device: device, width: side, height: side, pixels: fill(0, 1.6))
            let green = try Self.makeTexture(device: device, width: side, height: side, pixels: fill(1, 1.6))
            let blue = try Self.makeTexture(device: device, width: side, height: side, pixels: fill(2, 1.6))
            let output = try Self.makeTexture(device: device, width: side, height: side,
                                              pixels: [Float16](repeating: 0, count: side * side * 4))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
            var strength = strength
            var layerScale = SIMD3<Float>(1, 1, 1)
            var referenceSuperwhite: Float = 8
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(red, index: 1)
            encoder.setTexture(green, index: 2)
            encoder.setTexture(blue, index: 3)
            encoder.setTexture(output, index: 4)
            encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
            encoder.setBytes(&referenceSuperwhite, length: MemoryLayout<Float>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
            )
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            let values = try Self.readBack(output, device: device, queue: queue, width: side, height: side)
            return SIMD3(
                Self.appleLogDecode(Double(values[0])),
                Self.appleLogDecode(Double(values[1])),
                Self.appleLogDecode(Double(values[2]))
            )
        }

        let full = try run(strength: 1.0)
        #expect(abs(full.x - 0.38) < 0.004, "linear add + encode expected 0.38 (was \\(full.x))")
        #expect(abs(full.y - 0.38) < 0.004, "linear add + encode expected 0.38 (was \\(full.y))")
        #expect(abs(full.z - 0.38) < 0.004, "linear add + encode expected 0.38 (was \\(full.z))")

        let half = try run(strength: 0.5)
        #expect(abs(half.x - 0.28) < 0.004, "strength must scale the linear contribution (was \\(half.x))")
    }

    /// The apply kernel reads each layer's OWN channel. Three diffusion textures
    /// with energy in different channels pin this directly: a kernel that
    /// sampled `.r` from all three would add the decoy values instead.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationApplyReadsEachLayerChannel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let function = try #require(
            try Self.shaderLibrary(device: device).makeFunction(name: "spatial_halation_apply")
        )
        let pipeline = try device.makeComputePipelineState(function: function)
        let side = 16

        let source = Self.sourcePixels(width: side, height: side) { _, _ in SIMD3(0.18, 0.18, 0.18) }
        func uniform(_ fill: SIMD3<Float>) -> [Float16] {
            var pixels = [Float16](repeating: 0, count: side * side * 4)
            for index in 0..<(side * side) {
                pixels[index * 4] = Float16(fill.x)
                pixels[index * 4 + 1] = Float16(fill.y)
                pixels[index * 4 + 2] = Float16(fill.z)
                pixels[index * 4 + 3] = 1
            }
            return pixels
        }

        let sourceTexture = try Self.makeTexture(device: device, width: side, height: side, pixels: source)
        // Decoys in `.r` of the green and blue textures are what a wrong read picks up.
        let red = try Self.makeTexture(device: device, width: side, height: side, pixels: uniform(SIMD3(0.8, 0.9, 0.9)))
        let green = try Self.makeTexture(device: device, width: side, height: side, pixels: uniform(SIMD3(0.7, 0.5, 0.7)))
        let blue = try Self.makeTexture(device: device, width: side, height: side, pixels: uniform(SIMD3(0.6, 0.6, 0.4)))
        let output = try Self.makeTexture(device: device, width: side, height: side,
                                          pixels: [Float16](repeating: 0, count: side * side * 4))

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var strength: Float = 1.0
        var layerScale = SIMD3<Float>(1, 1, 1)
        var referenceSuperwhite: Float = 8
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(red, index: 1)
        encoder.setTexture(green, index: 2)
        encoder.setTexture(blue, index: 3)
        encoder.setTexture(output, index: 4)
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
        encoder.setBytes(&referenceSuperwhite, length: MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        let values = try Self.readBack(output, device: device, queue: queue, width: side, height: side)
        // 0.18 + 0.8/8 = 0.28, 0.18 + 0.5/8 = 0.2425, 0.18 + 0.4/8 = 0.23.
        let redOut = Self.appleLogDecode(Double(values[0]))
        let greenOut = Self.appleLogDecode(Double(values[1]))
        let blueOut = Self.appleLogDecode(Double(values[2]))
        #expect(abs(redOut - 0.28) < 0.004, "red must read the red layer (was \\(redOut))")
        #expect(abs(greenOut - 0.2425) < 0.004, "green must read the green layer (was \\(greenOut))")
        #expect(abs(blueOut - 0.23) < 0.004, "blue must read the blue layer (was \\(blueOut))")
    }

    // MARK: - Mask kernel (dispatched directly)

    /// Dispatch `spatial_halation_mask` directly and read the half-resolution
    /// mask back, so per-layer energy and the 2x2 downsample can be asserted
    /// exactly instead of inferred through the blur and composite.
    private static func halationMask(
        device: MTLDevice,
        queue: MTLCommandQueue,
        width: Int,
        height: Int,
        maskWidth: Int,
        maskHeight: Int,
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
        let mask = try makeTexture(
            device: device, width: maskWidth, height: maskHeight,
            pixels: [Float16](repeating: 0, count: maskWidth * maskHeight * 4)
        )

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var redKnee: Float = 1.0
        var greenKnee: Float = 2.0
        var blueKnee: Float = 4.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(mask, index: 1)
        encoder.setBytes(&redKnee, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&greenKnee, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&blueKnee, length: MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(width: (maskWidth + 15) / 16, height: (maskHeight + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        return try readBack(mask, device: device, queue: queue, width: maskWidth, height: maskHeight)
    }

    /// A subpixel superwhite must survive the half-resolution downsample.
    ///
    /// One 9x pixel in a 2x2 block with three 18% pixels averages to
    /// (9 + 3*0.18) / 4 = 2.385 of diffuse white, so red clears its 1.0 knee
    /// with 1.385 to spare and green clears its 2.0 knee. Averaging the ENCODED
    /// values and decoding once instead collapses that to ~0.49, below red's
    /// knee: the specular would vanish. The two outcomes are far apart, so this
    /// pins the decode-before-average order.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationMaskDecodesEachSampleBeforeAveraging() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())

        let mask = try Self.halationMask(
            device: device, queue: queue, width: 4, height: 4, maskWidth: 2, maskHeight: 2
        ) { column, row in
            (column == 0 && row == 0) ? SIMD3(9.0, 9.0, 9.0) : SIMD3(0.18, 0.18, 0.18)
        }

        // Mask texel (0,0) covers source pixels (0,0),(1,0),(0,1),(1,1).
        let red = Double(mask[0])
        let green = Double(mask[1])
        let blue = Double(mask[2])
        #expect(abs(red - 1.385) < 0.02, "red must preserve the subpixel specular (was \\(red))")
        #expect(abs(green - 0.385) < 0.02, "green must preserve the subpixel specular (was \\(green))")
        #expect(blue < 0.01, "blue is below its 4.0 knee and must stay dark (was \\(blue))")
    }

    /// A mask texel whose 2x2 block runs off an odd-sized frame must average the
    /// samples that exist, not always divide by four. Halving a partial block's
    /// energy can drop it below a knee and erase the highlight there.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationMaskAveragesOnlyValidPixelsForOddDimensions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())

        // 3x2 source into a 2x1 mask: the second mask texel covers source
        // columns 2 and 3, but column 3 does not exist, so only 2 samples are
        // valid. A uniform 2.5x-white source makes the expected energy exact
        // (red 1.5, green 0.5, blue 0) regardless of how many samples land.
        let mask = try Self.halationMask(
            device: device, queue: queue, width: 3, height: 2, maskWidth: 2, maskHeight: 1
        ) { _, _ in SIMD3(2.5, 2.5, 2.5) }

        // Texel (1,0): partial block, must equal the full-block value.
        let red = Double(mask[4])
        let green = Double(mask[5])
        let blue = Double(mask[6])
        #expect(abs(red - 1.5) < 0.02, "partial block must average its valid samples (was \\(red))")
        #expect(abs(green - 0.5) < 0.02, "partial block must average its valid samples (was \\(green))")
        #expect(blue < 0.01, "blue is below its 4.0 knee (was \\(blue))")

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
}
