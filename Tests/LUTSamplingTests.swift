import Foundation
import Metal
import Testing

/// Numerical tests for the production LUT kernel and `.cube` interpolation.
/// BabelColor sRGB points are sampling probes only, not Apple Log 2 inputs.
struct LUTSamplingTests {
    private struct RGB: Decodable, Sendable {
        let name: String
        let rgb8: [Int]

        var normalized: SIMD3<Float> {
            SIMD3(Float(rgb8[0]) / 255, Float(rgb8[1]) / 255, Float(rgb8[2]) / 255)
        }
    }

    private struct ColorChecker: Decodable {
        let reference: String
        let source: String
        let sourceNotes: String
        let patches: [RGB]
    }

    private struct Probe {
        let label: String
        let rgb: SIMD3<Float>
    }

    private struct Cube {
        let size: Int
        /// RGB triples in Resolve `.cube` order: red varies fastest.
        let rgb: [Float]

        static func identity(size: Int) -> Cube {
            var values = [Float]()
            values.reserveCapacity(size * size * size * 3)
            for blue in 0..<size {
                for green in 0..<size {
                    for red in 0..<size {
                        values.append(Float(red) / Float(size - 1))
                        values.append(Float(green) / Float(size - 1))
                        values.append(Float(blue) / Float(size - 1))
                    }
                }
            }
            return Cube(size: size, rgb: values)
        }

        func sample(_ value: SIMD3<Float>) -> SIMD3<Float> {
            let clamped = SIMD3(
                min(max(value.x, 0), 1),
                min(max(value.y, 0), 1),
                min(max(value.z, 0), 1)
            )
            let scaled = clamped * Float(size - 1)
            let lower = SIMD3(Int(floor(scaled.x)), Int(floor(scaled.y)), Int(floor(scaled.z)))
            let upper = SIMD3(min(lower.x + 1, size - 1), min(lower.y + 1, size - 1), min(lower.z + 1, size - 1))
            let weight = SIMD3(scaled.x - Float(lower.x), scaled.y - Float(lower.y), scaled.z - Float(lower.z))

            func node(_ red: Int, _ green: Int, _ blue: Int) -> SIMD3<Float> {
                let index = ((blue * size + green) * size + red) * 3
                return SIMD3(rgb[index], rgb[index + 1], rgb[index + 2])
            }

            func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
                a + (b - a) * t
            }

            let lowBlue = mix(
                mix(node(lower.x, lower.y, lower.z), node(upper.x, lower.y, lower.z), weight.x),
                mix(node(lower.x, upper.y, lower.z), node(upper.x, upper.y, lower.z), weight.x),
                weight.y
            )
            let highBlue = mix(
                mix(node(lower.x, lower.y, upper.z), node(upper.x, lower.y, upper.z), weight.x),
                mix(node(lower.x, upper.y, upper.z), node(upper.x, upper.y, upper.z), weight.x),
                weight.y
            )
            return mix(lowBlue, highBlue, weight.z)
        }
    }

    private struct GPUResult {
        let pipeline: MTLComputePipelineState
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func identityCubePreservesColorCheckerAndGridProbes() throws {
        let gpu = try Self.makeGPU()
        let fixture = try Self.loadColorChecker()
        #expect(fixture.patches.count == 24)
        let chartProbes = fixture.patches.map { Probe(label: $0.name, rgb: $0.normalized) }
        let probes = chartProbes + Self.boundaryAndRampProbes() + Self.identityGridKnots(size: 33)
        let cube = Cube.identity(size: 33)
        let output = try Self.run(probes.map(\.rgb), cube: cube, gpu: gpu)
        Self.expectMatches(output, probes: probes, cube: cube, tolerance: 0.0001,
                           context: "identity LUT; \(fixture.reference); \(fixture.source)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal GPU"))
    func shippedK2383CubesMatchIndependentTrilinearReference() throws {
        let gpu = try Self.makeGPU()
        let fixture = try Self.loadColorChecker()
        #expect(fixture.patches.count == 24)
        let probes = fixture.patches.map { Probe(label: $0.name, rgb: $0.normalized) }
            + Self.boundaryAndRampProbes()

        for lutName in [
            "50D K2383 - Apple Log 2.cube",
            "250D K2383 - Apple Log 2.cube",
            "200T K2383 - Apple Log 2.cube",
            "500T K2383 - Apple Log 2.cube"
        ] {
            let cube = try Self.parseCube(named: lutName)
            #expect(cube.size == 33, "\(lutName): expected 33³ cube")
            let output = try Self.run(probes.map(\.rgb), cube: cube, gpu: gpu)
            Self.expectMatches(output, probes: probes, cube: cube, tolerance: 0.001,
                               context: lutName)
        }
    }

    private static func makeGPU() throws -> GPUResult {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let shaderURL = root.appendingPathComponent("Resources/Shaders/pipeline.metal")
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "pass1_lut_halation_glow"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try #require(device.makeCommandQueue())
        return GPUResult(pipeline: pipeline, device: device, commandQueue: queue)
    }

    private static func run(_ probes: [SIMD3<Float>], cube: Cube, gpu: GPUResult) throws -> [SIMD3<Float>] {
        // All 33³ knots exceed a GPU's maximum single texture dimension.
        let width = min(probes.count, 1024)
        let height = (probes.count + width - 1) / width
        let input = try makeInputTexture(probes, width: width, height: height, device: gpu.device)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        outputDescriptor.usage = .shaderWrite
        outputDescriptor.storageMode = .shared
        let output = try #require(gpu.device.makeTexture(descriptor: outputDescriptor))
        let lut = try makeLUTTexture(cube, device: gpu.device)
        let commandBuffer = try #require(gpu.commandQueue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(gpu.pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        var noEffect: Float = 0
        var neutralContrast: Float = 1
        encoder.setBytes(&noEffect, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&noEffect, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&neutralContrast, length: MemoryLayout<Float>.size, index: 2)
        let widthPerGroup = max(1, gpu.pipeline.threadExecutionWidth)
        let groupCount = (width + widthPerGroup - 1) / widthPerGroup
        encoder.dispatchThreadgroups(
            MTLSize(width: groupCount, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: widthPerGroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw NSError(domain: "LUTSamplingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: commandBuffer.error?.localizedDescription
                            ?? "Metal command buffer finished with status \(commandBuffer.status.rawValue)"])
        }

        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (0..<probes.count).map { index in
            SIMD3(values[index * 4], values[index * 4 + 1], values[index * 4 + 2])
        }
    }

    private static func makeInputTexture(_ probes: [SIMD3<Float>], width: Int, height: Int,
                                         device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var values = [Float](repeating: 0, count: width * height * 4)
        for (index, probe) in probes.enumerated() {
            values[index * 4] = probe.x
            values[index * 4 + 1] = probe.y
            values[index * 4 + 2] = probe.z
            values[index * 4 + 3] = 1
        }
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size)
        }
        return texture
    }

    private static func makeLUTTexture(_ cube: Cube, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = cube.size
        descriptor.height = cube.size
        descriptor.depth = cube.size
        descriptor.mipmapLevelCount = 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var rgba = [Float]()
        rgba.reserveCapacity(cube.size * cube.size * cube.size * 4)
        for index in 0..<(cube.rgb.count / 3) {
            rgba.append(contentsOf: [cube.rgb[index * 3], cube.rgb[index * 3 + 1], cube.rgb[index * 3 + 2], 1])
        }
        rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size), mipmapLevel: 0,
                            slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: cube.size * 4 * MemoryLayout<Float>.size,
                            bytesPerImage: cube.size * cube.size * 4 * MemoryLayout<Float>.size)
        }
        return texture
    }

    private static func expectMatches(_ actual: [SIMD3<Float>], probes: [Probe], cube: Cube,
                                      tolerance: Float, context: String) {
        #expect(actual.count == probes.count)
        var failures: [String] = []
        for (index, probe) in probes.enumerated() {
            let expected = cube.sample(probe.rgb)
            let observed = actual[index]
            let error = max(abs(expected.x - observed.x), max(abs(expected.y - observed.y), abs(expected.z - observed.z)))
            if !observed.x.isFinite || !observed.y.isFinite || !observed.z.isFinite || !error.isFinite || error > tolerance {
                failures.append("\(probe.label): expected \(expected), got \(observed), max error \(error)")
                if failures.count == 5 { break }
            }
        }
        #expect(failures.isEmpty, "\(context): \(failures.joined(separator: "; "))")
    }

    private static func parseCube(named name: String) throws -> Cube {
        let url = root.appendingPathComponent("Resources/LUTs").appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values = [Float]()
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.uppercased().hasPrefix("TITLE") { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            if fields.first?.uppercased() == "LUT_3D_SIZE" {
                guard fields.count == 2, let parsedSize = Int(fields[1]) else {
                    throw NSError(domain: "LUTSamplingTests", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid LUT_3D_SIZE in \(name)"])
                }
                size = parsedSize
                continue
            }
            if fields.first?.uppercased() == "DOMAIN_MIN" || fields.first?.uppercased() == "DOMAIN_MAX" { continue }
            if let triplet = try? fields.map({ field -> Float in
                guard let value = Float(field) else { throw CubeParseError.invalidNumber }
                return value
            }), triplet.count == 3 {
                values.append(contentsOf: triplet)
            }
        }
        guard size > 1, values.count == size * size * size * 3 else {
            throw NSError(domain: "LUTSamplingTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Parsed \(values.count / 3) nodes for \(name), expected \(size)³"])
        }
        return Cube(size: size, rgb: values)
    }

    private static func loadColorChecker() throws -> ColorChecker {
        let url = root.appendingPathComponent("Tests/Fixtures/colorchecker-babelcolor-2006.json")
        return try JSONDecoder().decode(ColorChecker.self, from: Data(contentsOf: url))
    }

    private static func boundaryAndRampProbes() -> [Probe] {
        var probes: [Probe] = []
        for red in [Float(0), 1] {
            for green in [Float(0), 1] {
                for blue in [Float(0), 1] {
                    probes.append(Probe(label: "corner(\(red),\(green),\(blue))", rgb: SIMD3(red, green, blue)))
                }
            }
        }
        probes.append(Probe(label: "below-domain", rgb: SIMD3(-0.25, 0.4, 0.7)))
        probes.append(Probe(label: "above-domain", rgb: SIMD3(1.25, 0.3, 0.6)))
        for step in 0...32 {
            let value = Float(step) / 32
            probes.append(Probe(label: "red-ramp[\(step)]", rgb: SIMD3(value, 0.37, 0.71)))
            probes.append(Probe(label: "green-ramp[\(step)]", rgb: SIMD3(0.19, value, 0.83)))
            probes.append(Probe(label: "blue-ramp[\(step)]", rgb: SIMD3(0.61, 0.29, value)))
        }
        return probes
    }

    private static func identityGridKnots(size: Int) -> [Probe] {
        var probes: [Probe] = []
        probes.reserveCapacity(size * size * size)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let rgb = SIMD3(Float(red) / Float(size - 1), Float(green) / Float(size - 1), Float(blue) / Float(size - 1))
                    probes.append(Probe(label: "knot(\(red),\(green),\(blue))", rgb: rgb))
                }
            }
        }
        return probes
    }

    private enum CubeParseError: Error { case invalidNumber }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
