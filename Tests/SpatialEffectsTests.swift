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

    private static func makeTextures(device: MTLDevice) throws -> (graded: MTLTexture, pixels: [Float16]) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let graded = try #require(device.makeTexture(descriptor: descriptor))

        let pixels = gradedPixels()
        pixels.withUnsafeBytes { raw in
            graded.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float16>.size * 4
            )
        }
        return (graded, pixels)
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
        let (graded, _) = try Self.makeTextures(device: device)

        // Halation only: glow is deliberately excluded so this test pins the
        // tight halo rather than the frame-wide bloom, which is measured below.
        let output = try #require(stage.apply(
            graded: graded,
            commandQueue: queue,
            halationStrength: 0.5,
            glowStrength: 0,
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
            let (graded, _) = try Self.makeTextures(device: device)
            let output = try #require(stage.apply(
                graded: graded,
                commandQueue: queue,
                halationStrength: glow ? 0 : strength,
                glowStrength: glow ? strength : 0,
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
        let (graded, source) = try Self.makeTextures(device: device)

        let output = try #require(stage.apply(
            graded: graded,
            commandQueue: queue,
            halationStrength: 0,
            glowStrength: 0,
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
}
