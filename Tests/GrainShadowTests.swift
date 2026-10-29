import Foundation
import Metal
import Testing

/// Exercises the shipped grain volume and production grain kernel over flat
/// probes so grain cannot introduce a shadow-tone shift or clip positive detail.
@Suite("Grain shadow detail")
struct GrainShadowTests {
    private static let side = 128
    private static let frames: [UInt32] = [0, 17, 63, 127]
    private static let stockGrainSettings: [(iso: Float, grainSize: Float)] = [
        (50, 0.6), (250, 1.0), (200, 0.8), (500, 1.3)
    ]
    private static var benchmarkEnvironment: [String: String] { ProcessInfo.processInfo.environment }
    private static var benchmarkRequested: Bool {
        benchmarkEnvironment["GRAIN_BENCHMARK"] == "1"
            || benchmarkEnvironment["XCODE_TEST_GRAIN_BENCHMARK"] == "1"
    }

    private struct PixelStats {
        let mean: SIMD3<Double>
        let variance: SIMD3<Double>
        let blackClipped: SIMD3<Int>
        let whiteClipped: SIMD3<Int>
        let alphaMismatches: Int
        let channels: [[UInt8]]
        let width: Int
        let height: Int
    }

    /// Mirror of the production layout in `Resources/Shaders/grain.metal`. It has
    /// to stay byte-identical: the kernel reads the whole struct, so a short
    /// buffer would leave `chromaAmount` reading past the end.
    private struct GrainUniforms {
        var frameIndex: UInt32
        var iso: Float
        var grainSize: Float
        var edgeBoostMultiplier: Float = 0
        var gaugeAmplitude: Float = 1.0
        var chromaAmount: Float = GrainModel.videoChromaAmount
    }

    private final class BundleToken {}

    private static func metallib(device: MTLDevice) throws -> MTLLibrary {
        var directory = Bundle(for: BundleToken.self).bundleURL
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("default.metallib")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try device.makeLibrary(URL: candidate)
            }
            directory = directory.deletingLastPathComponent()
        }
        if let library = try? device.makeDefaultLibrary(bundle: .main) {
            return library
        }
        throw TestFailure("Production default.metallib not found near the test bundle")
    }

    private static func grainVolume(device: MTLDevice) throws -> MTLTexture {
        let bundleURL = Bundle(for: BundleToken.self).bundleURL
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        guard let url = enumerator?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "grain3d.raw" }) else {
            throw TestFailure("Required production fixture grain3d.raw is missing from the test bundle")
        }
        let data = try Data(contentsOf: url)
        let expectedByteCount = side * side * side * MemoryLayout<Float>.size
        guard data.count >= expectedByteCount else {
            throw TestFailure("grain3d.raw has \(data.count) bytes; expected at least \(expectedByteCount)")
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = side
        descriptor.height = side
        descriptor.depth = side
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TestFailure("Could not create the production grain volume texture")
        }
        data.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, side, side, side),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: side * MemoryLayout<Float>.size,
                bytesPerImage: side * side * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private static func texture(
        device: MTLDevice,
        format: MTLPixelFormat,
        usage: MTLTextureUsage,
        width: Int? = nil,
        height: Int? = nil
    ) throws -> MTLTexture {
        let width = width ?? side
        let height = height ?? side
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        guard let result = device.makeTexture(descriptor: descriptor) else {
            throw TestFailure("Could not create a \(format) probe texture")
        }
        return result
    }

    private static func inputTexture(
        device: MTLDevice,
        color: SIMD3<Float>,
        width: Int? = nil,
        height: Int? = nil
    ) throws -> MTLTexture {
        let width = width ?? side
        let height = height ?? side
        let input = try texture(device: device, format: .rgba16Float, usage: [.shaderRead], width: width, height: height)
        var values = [Float16](repeating: 1, count: width * height * 4)
        for pixel in 0..<(width * height) {
            values[pixel * 4] = Float16(color.x)
            values[pixel * 4 + 1] = Float16(color.y)
            values[pixel * 4 + 2] = Float16(color.z)
        }
        values.withUnsafeBytes { bytes in
            input.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float16>.size
            )
        }
        return input
    }

    private static func inputTexture(device: MTLDevice, values: [Float16]) throws -> MTLTexture {
        let input = try texture(device: device, format: .rgba16Float, usage: [.shaderRead])
        values.withUnsafeBytes { bytes in
            input.replace(
                region: MTLRegionMake2D(0, 0, side, side),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: side * 4 * MemoryLayout<Float16>.size
            )
        }
        return input
    }

    private static func edgeInputTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let input = try texture(device: device, format: .rgba16Float, usage: [.shaderRead], width: width, height: height)
        var values = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float16 = x < width / 2 ? 0.30 : 0.70
                let index = (y * width + x) * 4
                values[index] = value
                values[index + 1] = value
                values[index + 2] = value
            }
        }
        values.withUnsafeBytes { bytes in
            input.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float16>.size
            )
        }
        return input
    }

    private static func constantGrainVolume(device: MTLDevice) throws -> MTLTexture {
        let values = [Float](repeating: 0.5, count: side * side * side)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = side
        descriptor.height = side
        descriptor.depth = side
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TestFailure("Could not create constant grain volume")
        }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, side, side, side),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: side * MemoryLayout<Float>.size,
                bytesPerImage: side * side * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private static func run(
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        volume: MTLTexture,
        color: SIMD3<Float>,
        iso: Float,
        grainSize: Float,
        frame: UInt32,
        input inputOverride: MTLTexture? = nil,
        width requestedWidth: Int? = nil,
        height requestedHeight: Int? = nil,
        edgeBoostMultiplier: Float = 0,
        gaugeAmplitude: Float = 1.0,
        chromaAmount: Float = GrainModel.videoChromaAmount
    ) throws -> PixelStats {
        let width = requestedWidth ?? inputOverride?.width ?? side
        let height = requestedHeight ?? inputOverride?.height ?? side
        let input = try inputOverride ?? inputTexture(device: device, color: color, width: width, height: height)
        let output = try texture(device: device, format: .bgra8Unorm, usage: [.shaderWrite], width: width, height: height)
        var uniforms = GrainUniforms(
            frameIndex: frame, iso: iso, grainSize: grainSize,
            edgeBoostMultiplier: edgeBoostMultiplier, gaugeAmplitude: gaugeAmplitude,
            chromaAmount: chromaAmount
        )
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw TestFailure("Could not encode production grain kernel")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(volume, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw TestFailure("Production grain kernel failed: \(String(describing: command.error))")
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(
                bytes.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        var sums = SIMD3<Double>(repeating: 0)
        var sumsSquared = SIMD3<Double>(repeating: 0)
        var blacks = SIMD3<Int>(repeating: 0)
        var whites = SIMD3<Int>(repeating: 0)
        var alphaMismatches = 0
        var channels = Array(repeating: [UInt8](), count: 3)
        for channel in 0..<3 { channels[channel].reserveCapacity(width * height) }
        for pixel in 0..<(width * height) {
            if pixels[pixel * 4 + 3] != 255 { alphaMismatches += 1 }
            for channel in 0..<3 {
                let byteChannel = channel == 0 ? 2 : (channel == 2 ? 0 : 1)
                let value = Double(pixels[pixel * 4 + byteChannel]) / 255
                channels[channel].append(pixels[pixel * 4 + byteChannel])
                sums[channel] += value
                sumsSquared[channel] += value * value
                if pixels[pixel * 4 + byteChannel] == 0 { blacks[channel] += 1 }
                if pixels[pixel * 4 + byteChannel] == 255 { whites[channel] += 1 }
            }
        }
        let count = Double(width * height)
        let mean = sums / count
        let variance = sumsSquared / count - mean * mean
        return PixelStats(
            mean: mean, variance: variance, blackClipped: blacks,
            whiteClipped: whites, alphaMismatches: alphaMismatches, channels: channels,
            width: width, height: height
        )
    }

    private static func dispatchTimed(
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        volume: MTLTexture,
        input: MTLTexture,
        output: MTLTexture,
        frame: UInt32,
        iso: Float,
        grainSize: Float,
        edgeBoostMultiplier: Float
    ) throws -> TimeInterval {
        var uniforms = GrainUniforms(
            frameIndex: frame, iso: iso, grainSize: grainSize,
            edgeBoostMultiplier: edgeBoostMultiplier
        )
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw TestFailure("Could not encode isolated 4K grain benchmark")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(volume, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (input.width + 15) / 16, height: (input.height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw TestFailure("Isolated 4K grain benchmark failed: \(String(describing: command.error))")
        }
        let gpuDuration = command.gpuEndTime - command.gpuStartTime
        guard gpuDuration.isFinite, gpuDuration > 0 else {
            throw TestFailure("Metal GPU timestamps were unavailable for the isolated benchmark")
        }
        return gpuDuration
    }

    private static func context(_ color: SIMD3<Float>, _ stats: PixelStats, frame: UInt32) -> String {
        "probe=\(color), frame=\(frame), mean=\(stats.mean), variance=\(stats.variance), " +
            "blackClipped=\(stats.blackClipped), whiteClipped=\(stats.whiteClipped), " +
            "alphaMismatches=\(stats.alphaMismatches)"
    }

    private static func correlation(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        let meanL = lhs.reduce(0.0) { $0 + Double($1) } / Double(lhs.count)
        let meanR = rhs.reduce(0.0) { $0 + Double($1) } / Double(rhs.count)
        var covariance = 0.0
        var varianceL = 0.0
        var varianceR = 0.0
        for index in lhs.indices {
            let deltaL = Double(lhs[index]) - meanL
            let deltaR = Double(rhs[index]) - meanR
            covariance += deltaL * deltaR
            varianceL += deltaL * deltaL
            varianceR += deltaR * deltaR
        }
        let divisor = sqrt(varianceL * varianceR)
        return divisor > 0 ? covariance / divisor : 0
    }

    private static func lagCorrelation(
        _ values: [UInt8], width: Int, height: Int, dx: Int, dy: Int
    ) -> Double {
        var lhs = [UInt8]()
        var rhs = [UInt8]()
        let xStart = max(0, -dx)
        let xEnd = min(width, width - dx)
        let yStart = max(0, -dy)
        let yEnd = min(height, height - dy)
        lhs.reserveCapacity((xEnd - xStart) * (yEnd - yStart))
        rhs.reserveCapacity((xEnd - xStart) * (yEnd - yStart))
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                lhs.append(values[y * width + x])
                rhs.append(values[(y + dy) * width + x + dx])
            }
        }
        return correlation(lhs, rhs)
    }

    private static func horizontalNeighborPairs(_ values: [UInt8]) -> (left: [UInt8], right: [UInt8]) {
        var left = [UInt8]()
        var right = [UInt8]()
        left.reserveCapacity(side * (side - 1))
        right.reserveCapacity(side * (side - 1))
        for y in 0..<side {
            let row = y * side
            for x in 0..<(side - 1) {
                left.append(values[row + x])
                right.append(values[row + x + 1])
            }
        }
        return (left, right)
    }

    private static func chartValues() -> [Float16] {
        var values = [Float16](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let rgb: SIMD3<Float>
                switch y {
                case 0..<32:
                    let value = Float(x) / Float(side - 1)
                    rgb = SIMD3<Float>(repeating: value)
                case 32..<64:
                    let value: Float = x < side / 2 ? 0.18 : 0.82
                    rgb = SIMD3<Float>(repeating: value)
                case 64..<96:
                    let value: Float = ((x / 3 + y / 3) % 2 == 0) ? 0.25 : 0.75
                    rgb = SIMD3<Float>(repeating: value)
                default:
                    let patch = min(x / (side / 4), 3)
                    switch patch {
                    case 0: rgb = SIMD3<Float>(0.72, 0.16, 0.12)
                    case 1: rgb = SIMD3<Float>(0.12, 0.62, 0.20)
                    case 2: rgb = SIMD3<Float>(0.10, 0.24, 0.78)
                    default: rgb = SIMD3<Float>(0.72, 0.66, 0.14)
                    }
                }
                let index = (y * side + x) * 4
                values[index] = Float16(rgb.x)
                values[index + 1] = Float16(rgb.y)
                values[index + 2] = Float16(rgb.z)
            }
        }
        return values
    }

    private static func pipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: "pass2_grain") else {
            throw TestFailure("Required production kernel pass2_grain is missing")
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func setup() throws -> (MTLDevice, MTLCommandQueue, MTLComputePipelineState, MTLTexture) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestFailure("Metal GPU is unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw TestFailure("Could not create Metal command queue")
        }
        let library = try metallib(device: device)
        let pipeline = try Self.pipeline(device: device, library: library)
        return (device, queue, pipeline, try grainVolume(device: device))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func positiveShadowMeansStayStableWithoutNewBlackClipping() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        for setting in Self.stockGrainSettings {
            for level: Float in [0.03, 0.05, 0.10, 0.15] {
                let color = SIMD3<Float>(repeating: level)
                for frame in Self.frames {
                    let stats = try Self.run(
                        device: device, queue: queue, pipeline: pipeline, volume: volume,
                        color: color, iso: setting.iso, grainSize: setting.grainSize, frame: frame
                    )
                    let details = Self.context(color, stats, frame: frame)
                    let message = "\(details), iso=\(setting.iso), grainSize=\(setting.grainSize)"
                    #expect(stats.alphaMismatches == 0, "\(message)")
                    for channel in 0..<3 {
                        #expect(abs(stats.mean[channel] - Double(level)) <= 0.002, "\(message)")
                        #expect(stats.blackClipped[channel] == 0, "\(message)")
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func extremesRemainExactAndColorShadowsRetainTheirChannels() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        for value: Float in [0, 1] {
            let color = SIMD3<Float>(repeating: value)
            let stats = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 500, grainSize: 1.3, frame: 17, edgeBoostMultiplier: 3
            )
            let details = Self.context(color, stats, frame: 17)
            #expect(stats.mean == SIMD3<Double>(repeating: Double(value)), "\(details)")
            #expect(stats.variance == SIMD3<Double>(repeating: 0), "\(details)")
            #expect(stats.alphaMismatches == 0, "\(details)")
        }

        let color = SIMD3<Float>(0.03, 0.08, 0.15)
        for frame in Self.frames {
            let stats = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 500, grainSize: 1.3, frame: frame, edgeBoostMultiplier: 3
            )
            let details = Self.context(color, stats, frame: frame)
            #expect(stats.alphaMismatches == 0, "\(details)")
            for channel in 0..<3 {
                #expect(abs(stats.mean[channel] - Double(color[channel])) <= 0.002, "\(details)")
                #expect(stats.blackClipped[channel] == 0, "\(details)")
            }
        }
    }

    /// The still pipeline runs the same kernel as video with a much smaller dye-cloud
    /// term. A/B both amounts through the production kernel on one flat probe: the
    /// video amount has to stay chroma-visible, and the still amount has to be a
    /// small fraction of it, so a single still cannot read as coloured specks.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func stillGrainChromaIsAFractionOfTheVideoDyeCloudTerm() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)

        func chromaToLumaRatio(chromaAmount: Float) throws -> (ratio: Double, chroma: Double, luma: Double) {
            var chromaSamples = [Double]()
            var lumaSamples = [Double]()
            for frame in Self.frames {
                let stats = try Self.run(
                    device: device, queue: queue, pipeline: pipeline, volume: volume,
                    color: color, iso: 500, grainSize: 1.3, frame: frame,
                    chromaAmount: chromaAmount
                )
                for pixel in 0..<(stats.width * stats.height) {
                    let r = Double(stats.channels[0][pixel])
                    let g = Double(stats.channels[1][pixel])
                    let b = Double(stats.channels[2][pixel])
                    chromaSamples.append(r - b)
                    lumaSamples.append((r + g + b) / 3)
                }
            }
            func sigma(_ values: [Double]) -> Double {
                let mean = values.reduce(0, +) / Double(values.count)
                return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            }
            let chroma = sigma(chromaSamples)
            let luma = sigma(lumaSamples)
            return (chroma / max(luma, 0.0001), chroma, luma)
        }

        let video = try chromaToLumaRatio(chromaAmount: GrainModel.videoChromaAmount)
        let still = try chromaToLumaRatio(chromaAmount: GrainModel.stillChromaAmount)
        let message = String(
            format: "video chroma/luma = %.2f (chroma %.2f, luma %.2f) | still chroma/luma = %.2f (chroma %.2f, luma %.2f)",
            video.ratio, video.chroma, video.luma, still.ratio, still.chroma, still.luma
        )

        // Measured through the production kernel on this probe: video ~0.31, still ~0.08.
        // The video term has to stay visible; the still term has to sit near the 8-bit floor.
        #expect(video.ratio >= 0.25, "Video grain keeps its dye-cloud colour term: \(message)")
        #expect(still.ratio <= 0.12, "Still grain must read as luminance, not colour: \(message)")
        #expect(video.ratio >= still.ratio * 3.5, "The still chroma term must be a fraction of the video one: \(message)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func midtoneTextureRemainsVisibleAndScalesWithGauge() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)
        var quietVariance = 0.0
        var loudVariance = 0.0
        for frame in Self.frames {
            let quiet = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 400, grainSize: 1.3, frame: frame,
                gaugeAmplitude: PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
            )
            let loud = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 400, grainSize: 1.3, frame: frame,
                gaugeAmplitude: PrintGauge.eightMillimetre.amplitudeMultiplier
            )
            quietVariance += quiet.variance.x + quiet.variance.y + quiet.variance.z
            loudVariance += loud.variance.x + loud.variance.y + loud.variance.z
        }
        #expect(loudVariance > 0, "Midtone grain should remain visible at 8mm")
        #expect(loudVariance > quietVariance * 3,
                "Midtone grain should scale with the gauge: \(quietVariance) -> \(loudVariance)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func saturatedChannelsDoNotSuppressGrainInMidrangeChannels() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        for endpoint: Float in [0, 1] {
            let color = SIMD3<Float>(endpoint, 0.5, 0.5)
            let quiet = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 400, grainSize: 1.3, frame: 41,
                gaugeAmplitude: PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
            )
            let loud = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 400, grainSize: 1.3, frame: 41,
                gaugeAmplitude: PrintGauge.eightMillimetre.amplitudeMultiplier
            )
            let expectedEndpoint = endpoint == 0 ? 0.0 : 1.0
            #expect(quiet.mean.x == expectedEndpoint && loud.mean.x == expectedEndpoint,
                    "endpoint channel should stay exact: endpoint=\(endpoint), quiet=\(quiet.mean.x), loud=\(loud.mean.x)")
            #expect(quiet.variance.x == 0 && loud.variance.x == 0,
                    "endpoint channel should stay quiet: endpoint=\(endpoint)")
            for channel in 1..<3 {
                #expect(quiet.variance[channel] > 0, "midrange channel needs visible 75mm grain: \(color), \(quiet.variance)")
                #expect(loud.variance[channel] > quiet.variance[channel] * 3,
                        "midrange channel grain should scale with the gauge: \(color), \(quiet.variance) -> \(loud.variance)")
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainDoesNotRepeatAtTheOriginal128PixelLattice() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let stats = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: SIMD3<Float>(repeating: 0.5), iso: 500, grainSize: 1.3, frame: 31,
            width: 512, height: 512
        )
        #expect(stats.variance.x > 0, "large flat patch must contain measurable grain")
        let lags = [(169, 0), (0, 169), (169, 169), (339, 0), (0, 339), (339, 339)]
        for (dx, dy) in lags {
            let measured = Self.lagCorrelation(
                stats.channels[0], width: stats.width, height: stats.height, dx: dx, dy: dy
            )
            #expect(abs(measured) < 0.25, "unexpected repeated grain at lag (\(dx), \(dy)): correlation=\(measured)")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainHasAGrowingSpatialFootprintSharedAcrossColorChannels() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)
        let fine = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: 500, grainSize: 0.6, frame: 23
        )
        let coarse = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: 500, grainSize: 1.3, frame: 23
        )
        let fineNeighbors = Self.horizontalNeighborPairs(fine.channels[0])
        let coarseNeighbors = Self.horizontalNeighborPairs(coarse.channels[0])
        let fineNeighborCorrelation = Self.correlation(fineNeighbors.left, fineNeighbors.right)
        let coarseNeighborCorrelation = Self.correlation(coarseNeighbors.left, coarseNeighbors.right)
        let colorCorrelation = Self.correlation(coarse.channels[0], coarse.channels[1])
        #expect(coarseNeighborCorrelation > 0, "grain should have positive local correlation: \(coarseNeighborCorrelation)")
        #expect(coarseNeighborCorrelation > fineNeighborCorrelation + 0.05,
                "grain footprint should grow with size: \(fineNeighborCorrelation) -> \(coarseNeighborCorrelation)")
        #expect(colorCorrelation > 0.75, "grain should retain mostly shared RGB structure: \(colorCorrelation)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func printGaugeChangesFootprintAndAmplitudeIndependently() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)
        let iso: Float = 500
        let stockSize: Float = 1.3
        // ISO is fixed; only the gauge varies. Size and amplitude both come from
        // the gauge, and the 16mm rung is the reference.
        let fine = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: iso,
            grainSize: GrainModel.effectiveSize(stockGrainSize: stockSize, gauge: .seventyFiveMillimetre),
            frame: 23, gaugeAmplitude: PrintGauge.seventyFiveMillimetre.amplitudeMultiplier
        )
        let coarse = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: iso,
            grainSize: GrainModel.effectiveSize(stockGrainSize: stockSize, gauge: .eightMillimetre),
            frame: 23, gaugeAmplitude: PrintGauge.eightMillimetre.amplitudeMultiplier
        )
        let neutral = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: iso,
            grainSize: GrainModel.effectiveSize(stockGrainSize: stockSize, gauge: .thirtyFiveMillimetre),
            frame: 23, gaugeAmplitude: PrintGauge.thirtyFiveMillimetre.amplitudeMultiplier
        )
        // Size axis: the coarse gauge must be more spatially correlated.
        let fineNeighbors = Self.horizontalNeighborPairs(fine.channels[0])
        let coarseNeighbors = Self.horizontalNeighborPairs(coarse.channels[0])
        let fineCorrelation = Self.correlation(fineNeighbors.left, fineNeighbors.right)
        let coarseCorrelation = Self.correlation(coarseNeighbors.left, coarseNeighbors.right)
        #expect(coarseCorrelation > fineCorrelation,
                "footprint must grow from 75mm to 8mm: \(fineCorrelation) -> \(coarseCorrelation)")
        // Amplitude axis: 75mm is quieter than 35mm, which is quieter than 8mm.
        // The energy ratio does not collapse to the square of the amplitude ratio
        // because a gauge-independent fine-detail term floors it, so assert the
        // ordering plus a clear separation from the coarsest rung.
        let neutralEnergy = neutral.variance.x + neutral.variance.y + neutral.variance.z
        let fineEnergy = fine.variance.x + fine.variance.y + fine.variance.z
        let coarseEnergy = coarse.variance.x + coarse.variance.y + coarse.variance.z
        #expect(fineEnergy < neutralEnergy,
                "75mm must be quieter than 35mm at fixed ISO: \(fineEnergy) -> \(neutralEnergy)")
        #expect(neutralEnergy < coarseEnergy,
                "35mm must be quieter than 8mm at fixed ISO: \(neutralEnergy) -> \(coarseEnergy)")
        #expect(fineEnergy < coarseEnergy * 0.25,
                "75mm must be far quieter than 8mm: \(fineEnergy) vs \(coarseEnergy)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func grainChangesOverTimeWithoutFrameCyclingAndIsDeterministicPerFrame() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)
        let first = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: 500, grainSize: 1.3, frame: 0
        )
        let repeated = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: 500, grainSize: 1.3, frame: 0
        )
        let afterOldZLoop = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: color, iso: 500, grainSize: 1.3, frame: 128
        )
        #expect(first.channels == repeated.channels, "same frame/settings should render deterministically")
        #expect(first.channels != afterOldZLoop.channels, "frame 128 must not repeat frame 0")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func temporalGrainRMSStaysStableAcrossZEvolution() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        let color = SIMD3<Float>(repeating: 0.5)
        var frameRMS = [Double]()
        frameRMS.reserveCapacity(128)
        for frame in UInt32(0)..<UInt32(128) {
            let stats = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: color, iso: 500, grainSize: 1.3, frame: frame
            )
            frameRMS.append(sqrt((stats.variance.x + stats.variance.y + stats.variance.z) / 3))
        }
        let mean = frameRMS.reduce(0, +) / Double(frameRMS.count)
        let peakToPeak = (frameRMS.max()! - frameRMS.min()!) / mean
        #expect(peakToPeak < 0.25, "grain RMS should not pump with the animated z-slice: range/mean=\(peakToPeak)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func largerGrainSoftensEdgesWithoutRingingOrChangingFlatPatches() throws {
        let (device, queue, pipeline, _) = try Self.setup()
        let constantVolume = try Self.constantGrainVolume(device: device)
        var edge = [Float16](repeating: 1, count: Self.side * Self.side * 4)
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let value: Float16 = x < Self.side / 2 ? 0.18 : 0.82
                let index = (y * Self.side + x) * 4
                edge[index] = value
                edge[index + 1] = value
                edge[index + 2] = value
            }
        }
        let edgeInput = try Self.inputTexture(device: device, values: edge)
        let color = SIMD3<Float>(repeating: 0.5)
        let fine = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: constantVolume,
            color: color, iso: 500, grainSize: 0.6, frame: 9, input: edgeInput
        )
        let coarse = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: constantVolume,
            color: color, iso: 500, grainSize: 1.3, frame: 9, input: edgeInput
        )
        func edgeContrast(_ stats: PixelStats) -> Double {
            let total = (8..<(Self.side - 8)).reduce(0.0) { value, y in
                let row = y * Self.side
                return value + abs(Double(stats.channels[0][row + Self.side / 2] - stats.channels[0][row + Self.side / 2 - 1]))
            }
            return total / Double(Self.side - 16)
        }
        #expect(edgeContrast(coarse) < edgeContrast(fine),
                "larger grain should softly broaden the edge: \(edgeContrast(fine)) -> \(edgeContrast(coarse))")
        for value in coarse.channels[0] {
            #expect((46...209).contains(Int(value)), "positive prefilter weights must not ring or overshoot")
        }

        let flat = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: constantVolume,
            color: color, iso: 500, grainSize: 1.3, frame: 9
        )
        #expect(flat.channels.allSatisfy { Set($0).count == 1 }, "constant patches must remain byte-identical")
        #expect(abs(flat.mean.x - 0.5) <= 0.002, "constant patch mean should remain stable: \(flat.mean)")
        #expect(flat.alphaMismatches == 0, "alpha must survive prefiltering")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func edgeBoostChangesOnlyTransitionsAndKeepsRealVolumeFlatPatchesExact() throws {
        let (device, queue, pipeline, volume) = try Self.setup()
        var edge = [Float16](repeating: 1, count: Self.side * Self.side * 4)
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let index = (y * Self.side + x) * 4
                let rgb: SIMD3<Float16> = x < Self.side / 2
                    ? SIMD3<Float16>(0.30, 0.40, 0.45)
                    : SIMD3<Float16>(0.70, 0.60, 0.55)
                edge[index] = rgb.x
                edge[index + 1] = rgb.y
                edge[index + 2] = rgb.z
            }
        }
        let edgeInput = try Self.inputTexture(device: device, values: edge)
        let settings = (color: SIMD3<Float>(repeating: 0.5), iso: Float(500), grainSize: Float(1.3), frame: UInt32(27))
        let off = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: settings.color, iso: settings.iso, grainSize: settings.grainSize,
            frame: settings.frame, input: edgeInput
        )
        let on = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: settings.color, iso: settings.iso, grainSize: settings.grainSize,
            frame: settings.frame, input: edgeInput, edgeBoostMultiplier: 3
        )
        let flatBase = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: Self.constantGrainVolume(device: device),
            color: settings.color, iso: settings.iso, grainSize: settings.grainSize,
            frame: settings.frame, input: edgeInput
        )
        func transitionResidualVariance(_ stats: PixelStats) -> Double {
            var residuals = [Double]()
            for y in 0..<Self.side {
                for x in [Self.side / 2 - 1, Self.side / 2] {
                    let index = y * Self.side + x
                    for channel in 0..<3 {
                        residuals.append(Double(Int(stats.channels[channel][index]) - Int(flatBase.channels[channel][index])))
                    }
                }
            }
            let mean = residuals.reduce(0, +) / Double(residuals.count)
            return residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(residuals.count)
        }
        var distantDelta = 0
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let index = y * Self.side + x
                let delta = zip(off.channels, on.channels).reduce(0) { total, pair in
                    total + abs(Int(pair.0[index]) - Int(pair.1[index]))
                }
                if x != Self.side / 2 - 1 && x != Self.side / 2 {
                    distantDelta += delta
                }
            }
        }
        let offTransitionVariance = transitionResidualVariance(off)
        let onTransitionVariance = transitionResidualVariance(on)
        #expect(onTransitionVariance > offTransitionVariance * 1.15,
                "edge boost should increase real-volume residual variance at the transition: \(offTransitionVariance) -> \(onTransitionVariance)")
        #expect(distantDelta == 0, "pixels outside the source gradient must remain byte-identical")
        #expect(on.alphaMismatches == 0)
        #expect(on.blackClipped == SIMD3<Int>(repeating: 0))
        #expect(on.whiteClipped == SIMD3<Int>(repeating: 0))

        let flatOff = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: settings.color, iso: settings.iso, grainSize: settings.grainSize, frame: settings.frame
        )
        let flatOn = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: settings.color, iso: settings.iso, grainSize: settings.grainSize,
            frame: settings.frame, edgeBoostMultiplier: 3
        )
        #expect(flatOn.channels == flatOff.channels, "constant RGB must be byte-identical with edge boost")
        #expect(flatOn.mean == flatOff.mean)
        #expect(flatOn.variance == flatOff.variance)

        for invalidBoost: Float in [-1, 4, .nan, .infinity] {
            let invalid = try Self.run(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                color: settings.color, iso: settings.iso, grainSize: settings.grainSize,
                frame: settings.frame, input: edgeInput, edgeBoostMultiplier: invalidBoost
            )
            #expect(invalid.channels == off.channels, "invalid shader multiplier must disable edge boost")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func isolatedFourKEdgeBoostBenchmark() throws {
        guard Self.benchmarkRequested else { return }
        let (device, queue, pipeline, volume) = try Self.setup()
        let width = 3840
        let height = 2160
        let input = try Self.edgeInputTexture(device: device, width: width, height: height)
        let output = try Self.texture(device: device, format: .bgra8Unorm, usage: [.shaderWrite], width: width, height: height)
        let sampleCount = 20
        let warmupCount = 5
        let settings = (frame: UInt32(37), iso: Float(500), grainSize: Float(1.3))

        for index in 0..<warmupCount {
            let boost: Float = index.isMultiple(of: 2) ? 0 : 3
            _ = try Self.dispatchTimed(
                device: device, queue: queue, pipeline: pipeline, volume: volume,
                input: input, output: output, frame: settings.frame, iso: settings.iso,
                grainSize: settings.grainSize, edgeBoostMultiplier: boost
            )
        }

        var offTimes = [TimeInterval]()
        var onTimes = [TimeInterval]()
        offTimes.reserveCapacity(sampleCount)
        onTimes.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            if index.isMultiple(of: 2) {
                offTimes.append(try Self.dispatchTimed(
                    device: device, queue: queue, pipeline: pipeline, volume: volume,
                    input: input, output: output, frame: settings.frame, iso: settings.iso,
                    grainSize: settings.grainSize, edgeBoostMultiplier: 0
                ))
                onTimes.append(try Self.dispatchTimed(
                    device: device, queue: queue, pipeline: pipeline, volume: volume,
                    input: input, output: output, frame: settings.frame, iso: settings.iso,
                    grainSize: settings.grainSize, edgeBoostMultiplier: 3
                ))
            } else {
                onTimes.append(try Self.dispatchTimed(
                    device: device, queue: queue, pipeline: pipeline, volume: volume,
                    input: input, output: output, frame: settings.frame, iso: settings.iso,
                    grainSize: settings.grainSize, edgeBoostMultiplier: 3
                ))
                offTimes.append(try Self.dispatchTimed(
                    device: device, queue: queue, pipeline: pipeline, volume: volume,
                    input: input, output: output, frame: settings.frame, iso: settings.iso,
                    grainSize: settings.grainSize, edgeBoostMultiplier: 0
                ))
            }
        }

        let off = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: SIMD3<Float>(repeating: 0.5), iso: settings.iso,
            grainSize: settings.grainSize, frame: settings.frame, input: input,
            width: width, height: height, edgeBoostMultiplier: 0
        )
        let on = try Self.run(
            device: device, queue: queue, pipeline: pipeline, volume: volume,
            color: SIMD3<Float>(repeating: 0.5), iso: settings.iso,
            grainSize: settings.grainSize, frame: settings.frame, input: input,
            width: width, height: height, edgeBoostMultiplier: 3
        )

        var transitionByteDelta = 0
        var changedAwayFromTransition = 0
        var maximumByteDelta = 0
        let transitionColumns = [width / 2 - 1, width / 2]
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                var delta = 0
                for channel in 0..<3 {
                    delta += abs(Int(off.channels[channel][pixel]) - Int(on.channels[channel][pixel]))
                }
                maximumByteDelta = max(maximumByteDelta, delta)
                if transitionColumns.contains(x) {
                    transitionByteDelta += delta
                } else if delta != 0 {
                    changedAwayFromTransition += 1
                }
            }
        }
        #expect(transitionByteDelta > 0, "boosted benchmark must alter the edge response")
        #expect(changedAwayFromTransition == 0, "benchmark must preserve distant flat pixels")

        func median(_ values: [TimeInterval]) -> TimeInterval {
            let sorted = values.sorted()
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        let offMedian = median(offTimes)
        let onMedian = median(onTimes)
        let timingOverhead = onMedian - offMedian
        let timingOverheadPercent = timingOverhead / offMedian * 100
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let outputPath: URL
        if let explicitPath = Self.benchmarkEnvironment["GRAIN_BENCHMARK_OUTPUT"]
            ?? Self.benchmarkEnvironment["XCODE_TEST_GRAIN_BENCHMARK_OUTPUT"] {
            outputPath = URL(fileURLWithPath: explicitPath)
        } else {
            outputPath = root.appendingPathComponent(".pi/tmp/edge-grain-benchmark-2026-10-12.md")
        }
        try FileManager.default.createDirectory(at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report = """
        # Isolated 4K edge-grain GPU benchmark

        - Device: \(device.name)
        - Input: 3840×2160 RGBA16Float; output: 3840×2160 BGRA8Unorm; production `pass2_grain` kernel and shipped `grain3d.raw`
        - Settings: frame \(settings.frame), ISO \(settings.iso), grain size \(settings.grainSize)
        - Protocol: \(warmupCount) warm-up dispatches alternating boost 0/3; \(sampleCount) paired timed dispatches per setting, run serially with order alternating each pair
        - GPU load: no competing benchmark work was launched; background system or display GPU load was not measured
        - Boost 0 median: \(offMedian * 1000) ms (range \(offTimes.min()! * 1000)–\(offTimes.max()! * 1000) ms)
        - Boost 3 median: \(onMedian * 1000) ms (range \(onTimes.min()! * 1000)–\(onTimes.max()! * 1000) ms)
        - Timing overhead: \(timingOverhead * 1000) ms median (\(timingOverheadPercent)% versus boost 0)
        - Transition regression: summed RGB byte delta \(transitionByteDelta); maximum per-pixel RGB byte delta \(maximumByteDelta); changed pixels away from transition \(changedAwayFromTransition)
        - Limitation: timings describe this device/run and do not establish negligible cost on other devices or under different GPU load.
        """
        try report.write(to: outputPath, atomically: true, encoding: .utf8)
        print("Edge-grain benchmark report: \(outputPath.path)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func writesNativeSizeBeforeAndAfterPreviewWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["GRAIN_PREVIEW"] ?? environment["XCODE_TEST_GRAIN_PREVIEW"]) == "1" else { return }
        let (device, queue, currentPipeline, volume) = try Self.setup()
        guard let originalPath = environment["GRAIN_PREVIEW_METALLIB"] ?? environment["XCODE_TEST_GRAIN_PREVIEW_METALLIB"] else {
            throw TestFailure("XCODE_TEST_GRAIN_PREVIEW_METALLIB must point at the saved original default.metallib")
        }
        let originalLibrary = try device.makeLibrary(URL: URL(fileURLWithPath: originalPath))
        let originalPipeline = try Self.pipeline(device: device, library: originalLibrary)
        let chart = Self.chartValues()
        let chartInput = try Self.inputTexture(device: device, values: chart)
        let neutral = SIMD3<Float>(repeating: 0.5)
        let original = try Self.run(
            device: device, queue: queue, pipeline: originalPipeline, volume: volume,
            color: neutral, iso: 500, grainSize: 1.3, frame: 31, input: chartInput
        )
        let settings = Self.stockGrainSettings
        var panels = [original.channels]
        for setting in settings {
            let result = try Self.run(
                device: device, queue: queue, pipeline: currentPipeline, volume: volume,
                color: neutral, iso: setting.iso, grainSize: setting.grainSize, frame: 31, input: chartInput
            )
            panels.append(result.channels)
        }

        let panelCount = panels.count + 1
        var ppm = Data("P6\n\(panelCount * Self.side) \(Self.side)\n255\n".utf8)
        for y in 0..<Self.side {
            for panel in 0..<panelCount {
                for x in 0..<Self.side {
                    if panel == 0 {
                        let offset = (y * Self.side + x) * 4
                        for channel in 0..<3 {
                            ppm.append(UInt8(clamping: Int((Float(chart[offset + channel]) * 255).rounded())))
                        }
                    } else {
                        let pixel = y * Self.side + x
                        for channel in 0..<3 { ppm.append(panels[panel - 1][channel][pixel]) }
                    }
                }
            }
        }
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grain-shadow-preview.ppm")
        try ppm.write(to: output, options: .atomic)
        let legend = ["source", "original-5219", "50iso-size0.6", "250iso-size1.0", "200iso-size0.8", "500iso-size1.3"]
        let legendURL = output.deletingPathExtension().appendingPathExtension("json")
        try JSONEncoder().encode(legend).write(to: legendURL, options: .atomic)
        print("Grain preview: \(output.path) (\(panelCount * Self.side)x\(Self.side), \(legend.joined(separator: ", ")))")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
