import Foundation
import Testing
import Metal

/// Behavioural tests for the spatial halation/glow stage (epic story 1.4).
///
/// The effect this replaced was per-pixel: it could only brighten pixels that were
/// already bright, so a highlight never influenced its neighbours, and glow was a
/// constant frame-wide lift. These tests pin the properties that make the new
/// stage genuinely spatial, so a regression back to per-pixel behaviour fails:
///
///   1. light appears OUTSIDE the bright region (diffusion happened),
///   2. the added light is warm — red above green above blue,
///   3. the added light is LOCAL — far away the frame is untouched (this is what
///      distinguishes diffusion from the old constant glow),
///   4. zero strength is a no-op, so stock values of 0 really disable it.
///
/// Distinct from `GrainABITests`, which checks a struct layout, not behaviour.
struct SpatialEffectsTests {
    /// Thin structures expose sparse scaled taps that broad block averages hide.
    /// At 1024px, halation radius is 12.8 and glow radius is 25.6 half-res texels.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"),
          arguments: [false, true], [false, true])
    func thinHighlightHasContinuousOutwardTails(glow: Bool, horizontal: Bool) throws {
        let side = 1024
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let graded = try #require(device.makeTexture(descriptor: descriptor))
        // Exactly two half-res mask texels, symmetric about the image centre.
        // The background is above the shadow fade, but below highlight extraction.
        var pixels = [Float16](repeating: 0.125, count: side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let index = (row * side + column) * 4
                if (510..<514).contains(horizontal ? row : column) {
                    pixels[index] = 1
                    pixels[index + 1] = 1
                    pixels[index + 2] = 1
                }
                pixels[index + 3] = 1
            }
        }
        pixels.withUnsafeBytes { raw in
            graded.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                           withBytes: raw.baseAddress!, bytesPerRow: side * 8)
        }
        // Halation reads the UNGRADED frame, so this fixture needs its own Apple
        // Log 2 source: the same thin line as a superwhite (3x white) against an
        // 18% grey surround. Without it halation has no linear scene light to
        // work from and the test would measure nothing.
        let input = try #require(device.makeTexture(descriptor: descriptor))
        var sourcePixels = [Float16](repeating: Self.appleLogEncode(0.18), count: side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let index = (row * side + column) * 4
                if (510..<514).contains(horizontal ? row : column) {
                    let encoded = Self.appleLogEncode(3.0)
                    sourcePixels[index] = encoded
                    sourcePixels[index + 1] = encoded
                    sourcePixels[index + 2] = encoded
                }
                sourcePixels[index + 3] = 1
            }
        }
        sourcePixels.withUnsafeBytes { raw in
            input.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: side * 8)
        }
        let output = try #require(stage.apply(
            graded: graded, input: input, commandQueue: queue,
            halationStrength: glow ? 0 : 0.75, glowStrength: glow ? 0.75 : 0,
            halationRadiusFraction: 0.025, halationTint: SIMD3(1, 0.32, 0.10),
            width: side, height: side
        ))
        var result = [Float16](repeating: 0, count: pixels.count)
        let synchronize = try #require(queue.makeCommandBuffer())
        let blit = try #require(synchronize.makeBlitCommandEncoder())
        blit.synchronize(resource: output)
        blit.endEncoding()
        synchronize.commit()
        synchronize.waitUntilCompleted()
        #expect(synchronize.status == .completed)
        result.withUnsafeMutableBytes { raw in
            output.getBytes(raw.baseAddress!, bytesPerRow: side * 8,
                            from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        func addedLight(at coordinate: Int) -> Double {
            let index = horizontal ? (coordinate * side + side / 2) * 4
                : (side / 2 * side + coordinate) * 4
            return Double(result[index]) - 0.125
        }
        // Check individual pixels, not band averages. A detached lobe must not
        // recover after an earlier valley, even if it is below the main peak.
        // Two half-float steps allow readback/approximation noise, not ghost lobes.
        let tolerance = 0.00025
        var lowestSoFar = addedLight(at: 514)
        var largestRecovery = 0.0
        var largestAsymmetry = 0.0
        for distance in 0..<320 {
            let right = addedLight(at: 514 + distance)
            let left = addedLight(at: 509 - distance)
            largestRecovery = max(largestRecovery, right - lowestSoFar)
            lowestSoFar = min(lowestSoFar, right)
            largestAsymmetry = max(largestAsymmetry, abs(right - left))
        }
        #expect(largestRecovery <= tolerance,
                "outward tail must not form detached lobes (recovery=\(largestRecovery), glow=\(glow), horizontal=\(horizontal))")
        #expect(largestAsymmetry <= tolerance, "diffusion must remain symmetric about the thin highlight")
        // Two distinct properties, so two distances. CONTINUITY is checked across
        // the lit part of the tail: no dark gaps (the old sparse-tap kernel left
        // detached lobes here). DECAY is checked further out, where the tail must
        // have fallen away rather than lifting the frame. The decay distance grew
        // with the physical model because red now diffuses at 1.8x the base radius
        // — the tail is legitimately wider than the single shared radius it
        // replaced, and the old 96px sat inside it rather than past it.
        let litExtent = 96
        let minimumTail = (0..<litExtent).map { addedLight(at: 514 + $0) }.min()!
        #expect(minimumTail > 0.001, "added light must continuously fill the outward tail, not leave dark gaps")
        let decayExtent = 192
        #expect(addedLight(at: 514) > addedLight(at: 514 + decayExtent) + 0.001,
                "the tail must decay rather than lifting the whole frame")
    }

    private static let width = 256
    private static let height = 256

    /// Dark frame with one bright block, as Float16 RGBA samples.
    private static func gradedPixels() -> [Float16] {
        let dark: Float16 = 0.05
        let bright: Float16 = 0.8
        let blockLower = 100
        let blockUpper = 156
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let inBlock = column >= blockLower && column < blockUpper
                    && row >= blockLower && row < blockUpper
                let value: Float16 = inBlock ? bright : dark
                pixels.append(value)
                pixels.append(value)
                pixels.append(value)
                pixels.append(1)
            }
        }
        return pixels
    }

    /// Apple Log 2 encode — the inverse of the decode the shader applies.
    /// Constants are Apple's via OpenColorIO v2.6.0 `AppleCameras.cpp`, the same
    /// source the shader and the LUT generator use. Needed because halation now
    /// reads the UNGRADED frame, so fixtures have to be built as scene light and
    /// encoded, not written as graded pixels.
    static func appleLogEncode(_ linear: Double) -> Float16 {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236
        let beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
        let code = linear >= rt
            ? delta + gamma * log2(linear + beta)
            : c * (linear - r0) * (linear - r0)
        return Float16(code)
    }

    /// Linear scene light for the fixture: 18% grey surround, with the block as a
    /// superwhite source. At 3x diffuse white the block clears red's knee (1.0)
    /// and green's (2.0) but not blue's (4.0), so the halo must come out warm —
    /// which is the property the colour assertions below depend on.
    private static let blockLinear: Double = 3.0
    private static let surroundLinear: Double = 0.18

    private static func inputPixels() -> [Float16] {
        let blockLower = 100
        let blockUpper = 156
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let inBlock = column >= blockLower && column < blockUpper
                    && row >= blockLower && row < blockUpper
                let encoded = appleLogEncode(inBlock ? blockLinear : surroundLinear)
                pixels.append(encoded)
                pixels.append(encoded)
                pixels.append(encoded)
                pixels.append(1)
            }
        }
        return pixels
    }

    /// Mean per-channel value over a rectangle of an RGBA16Float readback buffer.
    private struct ChannelMeans {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func mean(
        _ values: [Float16],
        columns: Range<Int>,
        rows: Range<Int>
    ) -> ChannelMeans {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0
        for row in rows {
            for column in columns {
                let index = (row * width + column) * 4
                red += Double(values[index])
                green += Double(values[index + 1])
                blue += Double(values[index + 2])
                count += 1
            }
        }
        let divisor = Double(count)
        return ChannelMeans(red: red / divisor, green: green / divisor, blue: blue / divisor)
    }

    private static func makeTextures(
        device: MTLDevice
    ) throws -> (graded: MTLTexture, input: MTLTexture, pixels: [Float16]) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let graded = try #require(device.makeTexture(descriptor: descriptor))
        let input = try #require(device.makeTexture(descriptor: descriptor))

        let pixels = gradedPixels()
        pixels.withUnsafeBytes { raw in
            graded.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float16>.size * 4
            )
        }
        let source = inputPixels()
        source.withUnsafeBytes { raw in
            input.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float16>.size * 4
            )
        }
        return (graded, input, pixels)
    }

    /// Read an RGBA16Float texture back to CPU half floats.
    private static func readBack(
        _ texture: MTLTexture,
        device: MTLDevice,
        queue: MTLCommandQueue
    ) throws -> [Float16] {
        // Synchronize so managed storage is coherent before getBytes.
        if let synchronize = queue.makeCommandBuffer(), let blit = synchronize.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            synchronize.commit()
            synchronize.waitUntilCompleted()
        }
        var values = [Float16](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float16>.size * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return values
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

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationDiffusesOutsideTheHighlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let (graded, input, _) = try Self.makeTextures(device: device)

        // Halation only: glow is deliberately excluded so this test pins the
        // tight halo rather than the frame-wide bloom, which is measured below.
        let output = try #require(stage.apply(
            graded: graded,
            input: input,
            commandQueue: queue,
            halationStrength: 0.5,
            glowStrength: 0,
            halationRadiusFraction: 0.012,
            halationTint: SIMD3(1.0, 0.32, 0.10),
            width: Self.width,
            height: Self.height
        ))
        let result = try Self.readBack(output, device: device, queue: queue)

        // A band hugging the outside of the block, which is dark in the source.
        let adjacent = Self.mean(result, columns: 70..<99, rows: 110..<146)
        // Far corner, ~60px from the block edge — beyond the halation radius.
        let far = Self.mean(result, columns: 5..<40, rows: 5..<40)

        // Warm cast: light passing through the emulsion skews red.
        #expect(adjacent.red > adjacent.green)
        #expect(adjacent.green > adjacent.blue)

        // Far corner stays essentially untouched — proof the effect is local and
        // not the constant frame-wide lift the old per-pixel glow applied.
        // Measured: the source block edge is at x=100, this band spans 14-43px
        // from it, and halation decays to exactly the source level (0.0500) by
        // ~40px. So assert both "light was added here" and "nothing here".
        #expect(adjacent.red > 0.06, "halation must add light outside the bright block")
        #expect(far.red < 0.0505, "far field must stay at the source level, not be lifted")
        #expect(adjacent.red > far.red + 0.01)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func glowSpreadsWiderThanHalation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        // The block's right edge is at x=156. This band spans roughly 40-60 px
        // beyond it: past halation's reach, still within glow's.
        func farField(strength: Float, glow: Bool) throws -> Double {
            let (graded, input, _) = try Self.makeTextures(device: device)
            let output = try #require(stage.apply(
                graded: graded,
                input: input,
                commandQueue: queue,
                halationStrength: glow ? 0 : strength,
                glowStrength: glow ? strength : 0,
                halationRadiusFraction: 0.012,
                halationTint: SIMD3(1.0, 0.32, 0.10),
                width: Self.width,
                height: Self.height
            ))
            let result = try Self.readBack(output, device: device, queue: queue)
            return Self.mean(result, columns: 196..<216, rows: 100..<156).red
        }

        let halationFar = try farField(strength: 0.5, glow: false)
        let glowFar = try farField(strength: 0.5, glow: true)

        // Halation has decayed back to the untouched source level here, while
        // glow is still measurably lifting the frame that far out. This is the
        // property that separates a wide bloom from a tight halo.
        #expect(halationFar < 0.0505, "halation should not reach this far (was \(halationFar))")
        #expect(glowFar > halationFar + 0.003,
                "glow must reach further than halation (halation=\(halationFar), glow=\(glowFar))")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func zeroStrengthLeavesTheFrameUnchanged() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let (graded, input, source) = try Self.makeTextures(device: device)

        let output = try #require(stage.apply(
            graded: graded,
            input: input,
            commandQueue: queue,
            halationStrength: 0,
            glowStrength: 0,
            halationRadiusFraction: 0.012,
            halationTint: SIMD3(1.0, 0.32, 0.10),
            width: Self.width,
            height: Self.height
        ))
        let result = try Self.readBack(output, device: device, queue: queue)

        // Every sample matches the input: a stock with both effects at zero is a
        // pure passthrough, so disabling the look really disables it.
        for index in stride(from: 0, to: source.count, by: 4) {
            #expect(abs(Double(result[index]) - Double(source[index])) < 0.002)
        }
    }

    /// Per-stock halo geometry: two stocks with different radius and tint must
    /// produce measurably different halo spread AND colour, not merely a
    /// different intensity. 5207 (tight, saturated red) vs 5219 (wide, less
    /// saturated) per the published starting values.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func perStockGeometryChangesSpreadAndColour() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let sourceLevel = 0.05

        func measure(radiusFraction: Float, tint: SIMD3<Float>) throws -> (far: ChannelMeans, near: ChannelMeans) {
            let (graded, input, _) = try Self.makeTextures(device: device)
            let output = try #require(stage.apply(
                graded: graded,
                input: input,
                commandQueue: queue,
                halationStrength: 0.5,
                glowStrength: 0,
                halationRadiusFraction: radiusFraction,
                halationTint: tint,
                width: Self.width,
                height: Self.height
            ))
            let result = try Self.readBack(output, device: device, queue: queue)
            // Far band, ~40-60px beyond the block's right edge (x=156): a tight
            // halo has decayed here, a wide one still reaches. Source is dark.
            let far = Self.mean(result, columns: 196..<216, rows: 100..<156)
            // Band hugging the boundary, where both radii carry signal — used
            // for the colour comparison.
            let near = Self.mean(result, columns: 162..<182, rows: 100..<156)
            return (far, near)
        }

        let tight = try measure(radiusFraction: 0.008, tint: SIMD3(1.0, 0.20, 0.10))
        let wide = try measure(radiusFraction: 0.040, tint: SIMD3(1.0, 0.32, 0.10))

        // Spread: the wider per-stock radius adds more light further out.
        let tightFar = tight.far.red - sourceLevel
        let wideFar = wide.far.red - sourceLevel
        #expect(wideFar > tightFar + 0.002,
                "wider per-stock radius must spread further (tight=\(tightFar), wide=\(wideFar))")

        // Colour: the green/red ratio is the halo cast, independent of strength
        // and radius, so a tint change must move it.
        let tightRatio = (tight.near.green - sourceLevel) / (tight.near.red - sourceLevel)
        let wideRatio = (wide.near.green - sourceLevel) / (wide.near.red - sourceLevel)
        #expect(wideRatio > tightRatio + 0.05,
                "per-stock tint must change halo colour (tight=\(tightRatio), wide=\(wideRatio))")
    }

    /// The source brightens and grows, rather than being hollowed into a ring.
    ///
    /// This replaces `halationIsARingNotADisc`, which asserted the opposite — that
    /// the highlight centre receives LESS added light than the tail. That was the
    /// old implementation's intent: it subtracted the source's own highlight from
    /// the blurred mask to fake a ring. It is not what halation does. The
    /// reflected light lands across the source's footprint too, and because that
    /// energy accumulates and saturates toward white it makes a very bright source
    /// read as *larger* — the third characteristic of real halation, and the one
    /// the reference material calls out as missing from other implementations.
    /// So the centre must gain light, and the added light at the centre must
    /// exceed the added light in the tail outside it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationBrightensTheSourceCoreInsteadOfHollowingIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let (graded, input, _) = try Self.makeTextures(device: device)

        let output = try #require(stage.apply(
            graded: graded,
            input: input,
            commandQueue: queue,
            halationStrength: 0.5,
            glowStrength: 0,
            halationRadiusFraction: 0.012,
            halationTint: SIMD3(1.0, 0.32, 0.10),
            width: Self.width,
            height: Self.height
        ))
        let result = try Self.readBack(output, device: device, queue: queue)

        let bright: Double = 0.8
        let dark: Double = 0.05
        // Centre of the bright block (block spans 100..<156).
        let centre = Self.mean(result, columns: 118..<138, rows: 118..<138)
        // Tail hugging the outside of the block's left edge (x=100), dark in the
        // source.
        let tail = Self.mean(result, columns: 70..<99, rows: 110..<146)

        let centreAdded = centre.red - bright
        let tailAdded = tail.red - dark

        #expect(tailAdded > 0.005, "the tail outside the source must still be lit (was \(tailAdded))")
        #expect(centreAdded > 0,
                "the source core must gain light rather than being hollowed out (was \(centreAdded))")
        #expect(centreAdded > tailAdded,
                "added light at the source centre (\(centreAdded)) must exceed the tail (\(tailAdded)) — the source grows, it is not a ring")
    }

    // ======================================================================
    // Physical halation: per-layer channel and downsample regressions
    // ======================================================================
    //
    // The two defects these tests pin are invisible to any assertion on a
    // NEUTRAL source alone, because a neutral source puts equal energy in every
    // channel — an all-red mask blurred and then read from `.r` in all three
    // composite channels looks identical to a correct one. So the fixtures below
    // deliberately separate the channels: sources that sit between the per-layer
    // knees, and sources that are coloured, where "red's energy leaked into the
    // green and blue layers" changes the measured halo.

    /// Linear-scene-light fixture with independent per-channel block/surround
    /// values, encoded as Apple Log 2 for the ungraded input.
    private static func inputPixels(block: SIMD3<Double>, surround: SIMD3<Double>) -> [Float16] {
        let blockLower = 100
        let blockUpper = 156
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let inBlock = column >= blockLower && column < blockUpper
                    && row >= blockLower && row < blockUpper
                let value = inBlock ? block : surround
                pixels.append(appleLogEncode(value.x))
                pixels.append(appleLogEncode(value.y))
                pixels.append(appleLogEncode(value.z))
                pixels.append(1)
            }
        }
        return pixels
    }

    /// Graded texture (fixed dark/bright block, used only for the shadow fade)
    /// plus an ungraded input built from the supplied scene light.
    private static func makeTextures(
        device: MTLDevice,
        source: [Float16]
    ) throws -> (graded: MTLTexture, input: MTLTexture) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let graded = try #require(device.makeTexture(descriptor: descriptor))
        let input = try #require(device.makeTexture(descriptor: descriptor))

        let pixels = gradedPixels()
        pixels.withUnsafeBytes { raw in
            graded.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        source.withUnsafeBytes { raw in
            input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return (graded, input)
    }

    /// Run halation only and return the mean ADDED light in a band hugging the
    /// block's right edge (x=156), where the graded source is dark (0.05).
    /// Added light is measured per channel, so a channel that should be dark
    /// reads as zero and a channel fed the wrong layer's energy reads as lit.
    private static func halationAddedLight(
        device: MTLDevice,
        queue: MTLCommandQueue,
        stage: SpatialEffectsStage,
        source: [Float16],
        radiusFraction: Float,
        tint: SIMD3<Float>
    ) throws -> ChannelMeans {
        let (graded, input) = try makeTextures(device: device, source: source)
        let output = try #require(stage.apply(
            graded: graded,
            input: input,
            commandQueue: queue,
            halationStrength: 1.0,
            glowStrength: 0,
            halationRadiusFraction: radiusFraction,
            halationTint: tint,
            width: width,
            height: height
        ))
        let result = try readBack(output, device: device, queue: queue)
        let band = mean(result, columns: 160..<180, rows: 100..<156)
        let dark = 0.05
        return ChannelMeans(red: band.red - dark, green: band.green - dark, blue: band.blue - dark)
    }

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

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        inputDescriptor.usage = [.shaderRead, .shaderWrite]
        inputDescriptor.storageMode = .shared
        let input = try #require(device.makeTexture(descriptor: inputDescriptor))
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = linear(column, row)
                pixels.append(appleLogEncode(value.x))
                pixels.append(appleLogEncode(value.y))
                pixels.append(appleLogEncode(value.z))
                pixels.append(1)
            }
        }
        pixels.withUnsafeBytes { raw in
            input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }

        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: maskWidth, height: maskHeight, mipmapped: false
        )
        maskDescriptor.usage = [.shaderRead, .shaderWrite]
        maskDescriptor.storageMode = .shared
        let mask = try #require(device.makeTexture(descriptor: maskDescriptor))

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

        var values = [Float16](repeating: 0, count: maskWidth * maskHeight * 4)
        values.withUnsafeMutableBytes { raw in
            mask.getBytes(raw.baseAddress!, bytesPerRow: maskWidth * 8,
                          from: MTLRegionMake2D(0, 0, maskWidth, maskHeight), mipmapLevel: 0)
        }
        return values
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
        #expect(abs(red - 1.385) < 0.02, "red must preserve the subpixel specular (was \(red))")
        #expect(abs(green - 0.385) < 0.02, "green must preserve the subpixel specular (was \(green))")
        #expect(blue < 0.01, "blue is below its 4.0 knee and must stay dark (was \(blue))")
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
        #expect(abs(red - 1.5) < 0.02, "partial block must average its valid samples (was \(red))")
        #expect(abs(green - 0.5) < 0.02, "partial block must average its valid samples (was \(green))")
        #expect(blue < 0.01, "blue is below its 4.0 knee (was \(blue))")

        // Texel (0,0): full block, same uniform source, must agree.
        #expect(abs(Double(mask[0]) - red) < 0.02,
                "full and partial blocks of a uniform source must agree")
    }

    /// Neutral sources across the knee ladder must light exactly the layers
    /// whose knee they clear. Reading red's energy into the green/blue channels
    /// would light green and blue for a source that never reaches their knees.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationKneeLadderSelectsLayersByIntensity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))
        let grey = SIMD3<Double>(0.18, 0.18, 0.18)
        let tint = SIMD3<Float>(1.0, 0.32, 0.10)

        func halo(_ level: Double) throws -> ChannelMeans {
            try Self.halationAddedLight(
                device: device, queue: queue, stage: stage,
                source: Self.inputPixels(block: SIMD3(level, level, level), surround: grey),
                radiusFraction: 0.03, tint: tint
            )
        }

        // 1.5x: clears red's 1.0 knee only.
        let redOnly = try halo(1.5)
        // 3.0x: clears red and green, still below blue's 4.0.
        let redGreen = try halo(3.0)
        // 8.0x: clears all three.
        let allLayers = try halo(8.0)

        #expect(redOnly.red > 0.001, "red must respond above its 1.0 knee (was \(redOnly.red))")
        #expect(redOnly.green < redOnly.red * 0.1,
                "green must stay dark below its 2.0 knee (was \(redOnly.green))")
        #expect(redOnly.blue < redOnly.red * 0.1,
                "blue must stay dark below its 4.0 knee (was \(redOnly.blue))")

        #expect(redGreen.green > 0.001, "green must respond above its 2.0 knee (was \(redGreen.green))")
        #expect(redGreen.blue < redGreen.green * 0.1,
                "blue must stay dark below its 4.0 knee (was \(redGreen.blue))")

        #expect(allLayers.blue > 0.001, "blue must respond above its 4.0 knee (was \(allLayers.blue))")
    }

    /// An all-red source exposes only the red layer, so its halo must stay red.
    /// If the composite read `.r` from the green and blue diffusions, red's
    /// diffused energy would light them and the source would masquerade as RGB.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func colouredSourceDoesNotLightOtherLayers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try SpatialEffectsStage(device: device, library: try Self.shaderLibrary(device: device))

        // Block: red at 3x diffuse white, green/blue at 18% grey. Only red is
        // above its knee, so the mask is (red, 0, 0).
        let halo = try Self.halationAddedLight(
            device: device, queue: queue, stage: stage,
            source: Self.inputPixels(
                block: SIMD3(3.0, 0.18, 0.18),
                surround: SIMD3(0.18, 0.18, 0.18)
            ),
            radiusFraction: 0.03, tint: SIMD3<Float>(1.0, 0.32, 0.10)
        )

        #expect(halo.red > 0.001, "the red layer must respond (was \(halo.red))")
        #expect(halo.green < halo.red * 0.1,
                "an all-red source must not light the green layer (was \(halo.green))")
        #expect(halo.blue < halo.red * 0.1,
                "an all-red source must not light the blue layer (was \(halo.blue))")
    }

    /// The composite must read each layer's own channel. Three diffusion
    /// textures with energy in different channels pin this directly: a kernel
    /// that samples `.r` from all three would add red only.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationCompositeReadsEachLayerChannel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let function = try #require(
            try Self.shaderLibrary(device: device).makeFunction(name: "spatial_halation_composite")
        )
        let pipeline = try device.makeComputePipelineState(function: function)

        let side = 16
        func texture(_ fill: SIMD4<Float16>) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            var pixels = [Float16]()
            pixels.reserveCapacity(side * side * 4)
            for _ in 0..<(side * side) {
                pixels.append(contentsOf: [fill.x, fill.y, fill.z, fill.w])
            }
            pixels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: side * 8)
            }
            return texture
        }

        let graded = try texture(SIMD4(0.5, 0.5, 0.5, 1))
        // Each diffusion carries energy in a DIFFERENT channel; the decoys in
        // `.r` of the green and blue textures are what a wrong read picks up.
        let red = try texture(SIMD4(0.8, 0, 0, 1))
        let green = try texture(SIMD4(0, 0.6, 0, 1))
        let blue = try texture(SIMD4(0, 0, 0.4, 1))
        let output = try texture(SIMD4(0, 0, 0, 1))

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var strength: Float = 1.0
        var shadowFloor: Float = 0.08
        var layerScale = SIMD3<Float>(1, 1, 1)
        var referenceSuperwhite: Float = 1.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(graded, index: 0)
        encoder.setTexture(red, index: 1)
        encoder.setTexture(green, index: 2)
        encoder.setTexture(blue, index: 3)
        encoder.setTexture(output, index: 4)
        encoder.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&shadowFloor, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&layerScale, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        encoder.setBytes(&referenceSuperwhite, length: MemoryLayout<Float>.size, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var values = [Float16](repeating: 0, count: side * side * 4)
        values.withUnsafeMutableBytes { raw in
            output.getBytes(raw.baseAddress!, bytesPerRow: side * 8,
                            from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        // shadowWeight at luma 0.5 is 1, so added light is (0.8, 0.6, 0.4).
        #expect(abs(Double(values[0]) - 1.3) < 0.01, "red channel (was \(values[0]))")
        #expect(abs(Double(values[1]) - 1.1) < 0.01, "green channel must read the green layer (was \(values[1]))")
        #expect(abs(Double(values[2]) - 0.9) < 0.01, "blue channel must read the blue layer (was \(values[2]))")
    }
}
