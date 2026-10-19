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
}
