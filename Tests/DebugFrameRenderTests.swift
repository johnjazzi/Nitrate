import Foundation
import Testing
import Metal
import CoreVideo

/// Headless cover for the debug single-frame render path.
///
/// The camera capture side cannot run on the simulator, so this drives
/// `PipelineRenderer.renderDebugFrame` directly with a synthetic `CVPixelBuffer`
/// in the same 64RGBAHalf layout the offline decoder produces. It pins:
///   1. one frame renders at the right size,
///   2. halation strength actually reaches the spatial stage (warm light appears
///      outside a highlight), and
///   3. the print gauge actually reaches the grain stage (coarse vs fine gauge
///      changes the output pixels). The gauge owns grain size *and* presence, so
///      it — not ISO — is the grain axis.
@Suite(.serialized)
struct DebugFrameRenderTests {
    private final class BundleToken {}

    private static let width = 128
    private static let height = 128
    /// LUT maps Apple Log 0.5 → ~0.43 luma (full grain latitude) and 0.9 → ~0.95
    /// luma (a highlight the halation mask picks up).
    private static let background: Float16 = 0.5
    private static let highlight: Float16 = 0.9
    private static let blockLower = 48
    private static let blockUpper = 80

    private struct ChannelMeans {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Mid-grey RGBA-half frame with a bright central block, in the 64RGBAHalf
    /// layout the decoder hands pass1. The values are Apple Log 2 CODE values
    /// (the decoder output), so a higher `highlight` code is a larger linear
    /// scene-light excess above the per-layer knees.
    private static func makeSyntheticFrame(
        background: Float16 = 0.5, highlight: Float16 = 0.9
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary,
                                         &optionalBuffer)
        let frame = try #require(optionalBuffer)
        #expect(status == kCVReturnSuccess)
        #expect(CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let base = try #require(CVPixelBufferGetBaseAddress(frame))
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                let inBlock = x >= blockLower && x < blockUpper && y >= blockLower && y < blockUpper
                let value = inBlock ? highlight : background
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 1
            }
        }
        return frame
    }

    private struct Frame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]
    }

    /// Tightly packed BGRA8 readback of a rendered debug frame.
    private func read(_ buffer: CVPixelBuffer) throws -> Frame {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width * 4) {
                pixels[y * width * 4 + x] = base[y * rowBytes + x]
            }
        }
        return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
    }

    /// Mean channel values over a rectangle, from a BGRA8 frame.
    private func mean(_ frame: Frame, columns: Range<Int>, rows: Range<Int>) -> ChannelMeans {
        var blue = 0.0, green = 0.0, red = 0.0
        var count = 0
        for y in rows {
            for x in columns {
                let index = y * frame.bytesPerRow + x * 4
                blue += Double(frame.pixels[index])
                green += Double(frame.pixels[index + 1])
                red += Double(frame.pixels[index + 2])
                count += 1
            }
        }
        let divisor = Double(max(count, 1))
        return ChannelMeans(red: red / divisor, green: green / divisor, blue: blue / divisor)
    }

    private var testBundle: Bundle { Bundle(for: BundleToken.self) }

    private func loadConfig() throws -> FilmStockConfig {
        let url = testBundle.url(forResource: "stocks", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../App/Resources/stocks.json").standardizedFileURL
        let container = try JSONDecoder().decode(Container.self, from: Data(contentsOf: url))
        return try #require(container.stocks.first { $0.stockId == "kodak5219" })
    }

    private struct Container: Decodable { let stocks: [FilmStockConfig] }

    private func makeRenderer() throws -> PipelineRenderer {
        try PipelineRenderer(resourceBundle: testBundle)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func singleFrameRenderReturnsAnImageOfTheSourceSize() throws {
        let renderer = try makeRenderer()
        let config = try loadConfig()
        let frame = try Self.makeSyntheticFrame()

        let result = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config,
            parameters: PipelineRenderer.DebugFrameParameters(config: config)
        ))
        #expect(result.width == Self.width)
        #expect(result.height == Self.height)
        #expect(result.texture.width == Self.width)
        #expect(result.texture.height == Self.height)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationStrengthChangesTheOutputPixels() throws {
        let renderer = try makeRenderer()
        let config = try loadConfig()
        let frame = try Self.makeSyntheticFrame()

        var none = PipelineRenderer.DebugFrameParameters(config: config)
        none.halationStrength = 0
        none.glowStrength = 0
        // Pin a radius that reaches the measured band rather than relying on the
        // stock's small default, which at this 128px frame diffuses only a few px.
        none.halationRadiusFraction = 0.03
        var strong = none
        strong.halationStrength = 0.9

        let noneRender = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: none))
        let strongRender = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: strong))

        let noneFrame = try read(noneRender.pixelBuffer)
        let strongFrame = try read(strongRender.pixelBuffer)

        // Band hugging the outside of the bright block (block right edge x=80):
        // dark background in the source, where halation bleeds light.
        let noneBand = mean(noneFrame, columns: 82..<100, rows: 52..<76)
        let strongBand = mean(strongFrame, columns: 82..<100, rows: 52..<76)

        let redDelta = (strongBand.red - noneBand.red) / 255.0
        let greenDelta = (strongBand.green - noneBand.green) / 255.0

        #expect(redDelta > 0.01,
                "halation strength must add light outside the highlight (red delta \\(redDelta))")
        #expect(redDelta > greenDelta,
                "halation light must be red-dominant (red \\(redDelta) vs green \\(greenDelta))")
    }

    @Test func debugHalationSliderAllowsAmplificationAndFineRadiusTuning() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/Modules/CameraCapture/DebugFrameSheet.swift"), encoding: .utf8)
        let section = try #require(source.components(separatedBy: "private var halationSection: some View {").last)
            .components(separatedBy: "private var glowSection: some View {")[0]
        #expect(section.contains("in: 0...8, step: 0.01"), "Halation strength must allow gain above the old ceiling")
        #expect(section.contains("in: 0.0005...0.0030, step: 0.0001"), "Radius tuning must cover the requested fine range and increments")
        #expect(section.components(separatedBy: "in: 0...1, step: 0.01").count == 4,
                "The three channel-weight dials must retain their existing range")
        // The sheet must state the real order of operations, not a placeholder.
        #expect(source.contains("halation (scene-linear, pre-LUT)"),
                "The debug sheet must truthfully label halation as pre-LUT")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func debugHalationGainAboveOneReachesTheRenderedPixels() throws {
        let renderer = try makeRenderer()
        let config = try loadConfig()
        let frame = try Self.makeSyntheticFrame()
        var parameters = PipelineRenderer.DebugFrameParameters(config: config)
        parameters.glowStrength = 0
        parameters.presenceMultiplier = 0
        parameters.halationStrength = 1
        parameters.halationRadiusFraction = 0.03
        let reference = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: parameters))
        let referenceFrame = try read(reference.pixelBuffer)
        parameters.halationStrength = 8
        let amplified = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: parameters))
        let amplifiedFrame = try read(amplified.pixelBuffer)
        let referenceBand = mean(referenceFrame, columns: 82..<100, rows: 52..<76)
        let amplifiedBand = mean(amplifiedFrame, columns: 82..<100, rows: 52..<76)
        #expect(amplifiedBand.red > referenceBand.red + 10,
                "Gain above one must visibly increase halation, not be clamped before rendering")
    }

    /// A uniform source with zero diffusion has an independent CPU reference:
    /// add the per-layer excess in linear, encode, then run that new source
    /// through the same LUT with halation disabled. This pins the render order
    /// without making assumptions about the film LUT's nonlinear brightness.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func halationIsGradedThroughTheSameLUTAsTheSource() throws {
        let renderer = try makeRenderer()
        let config = try loadConfig()
        let code: Float16 = 0.8
        let frame = try Self.makeSyntheticFrame(background: code, highlight: code)
        var parameters = PipelineRenderer.DebugFrameParameters(config: config)
        parameters.glowStrength = 0
        parameters.presenceMultiplier = 0
        parameters.halationStrength = 4
        parameters.halationRadiusFraction = 0
        let rendered = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: parameters))
        let actual = try read(rendered.pixelBuffer)

        // Uniform input means the half-resolution mask is uniform as well, so
        // its exact expected contribution needs no blur or GPU implementation.
        let linear = pow(2.0, (Double(code) - 0.69336945) / 0.08550479) - 0.00964052
        let knees = [1.0, 2.0, 4.0]
        let scales = [Double(parameters.halationTint.x), Double(parameters.halationTint.y),
                      Double(parameters.halationTint.z)]
        let expectedCodes = zip(knees, scales).map { knee, scale -> Float16 in
            let combined = linear + max(0, linear - knee) * scale * 4 / 8
            return Float16(0.69336945 + 0.08550479 * log2(combined + 0.00964052))
        }
        let expectedSource = try Self.makeSyntheticFrame(background: code, highlight: code)
        #expect(CVPixelBufferLockBaseAddress(expectedSource, []) == kCVReturnSuccess)
        let base = try #require(CVPixelBufferGetBaseAddress(expectedSource))
        let rowBytes = CVPixelBufferGetBytesPerRow(expectedSource)
        for y in 0..<Self.height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<Self.width {
                for channel in 0..<3 { row[x * 4 + channel] = expectedCodes[channel] }
            }
        }
        CVPixelBufferUnlockBaseAddress(expectedSource, [])
        parameters.halationStrength = 0
        let reference = try #require(renderer.renderDebugFrame(
            pixelBuffer: expectedSource, config: config, parameters: parameters))
        let expected = try read(reference.pixelBuffer)
        let maximumDifference = zip(actual.pixels, expected.pixels)
            .map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
        #expect(maximumDifference <= 2,
                "Halation must enter the LUT as added scene light (max byte difference \(maximumDifference))")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func printGaugeChangesTheGrainOutputPixels() throws {
        let renderer = try makeRenderer()
        let config = try loadConfig()
        let frame = try Self.makeSyntheticFrame()

        var coarse = PipelineRenderer.DebugFrameParameters(config: config)
        coarse.applyGauge(.eightMillimetre)      // size x 3.0, presence x 1.00
        coarse.halationStrength = 0
        coarse.glowStrength = 0
        var fine = coarse
        fine.applyGauge(.seventyFiveMillimetre)  // size x 0.55, presence x 0.04

        // The gauge must actually move the grain axes it owns.
        #expect(coarse.realizedFootprint > fine.realizedFootprint)
        #expect(coarse.gaugeAmplitude > fine.gaugeAmplitude)

        let coarseRender = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: coarse))
        let fineRender = try #require(renderer.renderDebugFrame(
            pixelBuffer: frame, config: config, parameters: fine))

        let coarseFrame = try read(coarseRender.pixelBuffer)
        let fineFrame = try read(fineRender.pixelBuffer)

        var differingPixels = 0
        for index in stride(from: 0, to: coarseFrame.pixels.count, by: 4)
        where abs(Int(coarseFrame.pixels[index]) - Int(fineFrame.pixels[index])) > 4 {
            differingPixels += 1
        }
        let totalPixels = Self.width * Self.height
        #expect(differingPixels > totalPixels / 20,
                "the print gauge must change the grain output (\\(differingPixels)/\\(totalPixels) pixels differ)")
    }
}
