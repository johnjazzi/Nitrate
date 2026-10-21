import Foundation
import Metal
import Testing
import simd

/// Regression tests for the stock-selector plate preview's colour path.
///
/// The preview's first pass -- `plate_prepare` in `Resources/Shaders/camera-preview.metal` --
/// is the only place the app decodes Apple Log 2 to linear light, applies a white-balance
/// transform and re-encodes. It runs BEFORE halation and the LUT, so the halo scatters the
/// light the camera's lock actually produced. Two defects lived in this step: the Log toe was
/// linear instead of a square root (so the decode threshold and the inverse were both wrong),
/// and the white-balance transform was a diagonal derived in linear sRGB but applied to Apple
/// Wide Gamut values. These tests run the shipping kernel on real Metal textures and pin the
/// correction, using the Apple Log 2 curve and Apple Wide Gamut primaries from the Apple Log 2
/// white paper as copied in OpenColorIO 2.6 (`AppleCameras.cpp`,
/// `APPLE_LOG-APPLEWG_to_ACES2065-1`).
struct PlatePreviewColourTests {
    private final class BundleToken {}

    // MARK: - Shipping kernel on real textures

    /// Run a row of plate codes through `plate_prepare`, so the kernel's own decode -> white
    /// balance -> encode is what the read-back measures. The kernel reads and writes 1:1, so a
    /// single row of codes is enough.
    private func render(_ codes: [Float], whiteBalance: simd_float3x3) throws -> [[Float]] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: BundleToken.self))
        let function = try #require(library.makeFunction(name: "plate_prepare"))
        let pipeline = try device.makeComputePipelineState(function: function)

        let width = codes.count
        let plate = try make2D(device, format: .rgba32Float, width: width)
        var plateValues = [Float]()
        for code in codes { plateValues.append(contentsOf: [code, code, code, 1]) }
        plateValues.withUnsafeBytes {
            plate.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        let output = try make2D(device, format: .rgba32Float, width: width)

        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        var uniforms = PlatePrepareUniformsCPU(whiteBalance: whiteBalance)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(plate, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PlatePrepareUniformsCPU>.stride, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)

        var pixels = [Float](repeating: 0, count: width * 4)
        pixels.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                            from: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0)
        }
        return (0..<width).map { index in
            [pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2]]
        }
    }

    private func make2D(_ device: any MTLDevice, format: MTLPixelFormat,
                        width: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    // MARK: - Tests

    /// Identity white balance must be identity everywhere, including in the toe where the old
    /// linear-toe round trip collapsed any code below ~0.209 to roughly 0.0014.
    @Test func identityWhiteBalancePreservesEveryPlateCodeAcrossTheToe() throws {
        let codes: [Float] = [0, 0.001, 0.01, 0.05, 0.1, 0.15, 0.2, 0.2086, 0.25, 0.4, 0.488, 0.7, 1.0]
        let rendered = try render(codes, whiteBalance: matrix_identity_float3x3)
        for (index, code) in codes.enumerated() {
            for channel in 0..<3 {
                let value = rendered[index][channel]
                #expect(abs(value - code) < 5e-4,
                        "identity white balance changed code \(code) to \(value)")
            }
        }
    }

    /// The shipping kernel must reproduce the official Apple Log 2 curve: decode, apply a
    /// scalar gain, re-encode. A linear toe fails this for every code below the join.
    @Test func shaderMatchesTheOfficialAppleLog2CurveUnderAScalarGain() throws {
        let codes: [Float] = [0.02, 0.05, 0.1, 0.15, 0.2, 0.2086, 0.25, 0.35, 0.5, 0.65, 0.8]
        let gain: Float = 2
        let rendered = try render(codes, whiteBalance: simd_float3x3(diagonal: SIMD3(repeating: gain)))
        for (index, code) in codes.enumerated() {
            let expected = AppleLog2.encode(AppleLog2.decode(Double(code)) * Double(gain))
            for channel in 0..<3 {
                let value = Double(rendered[index][channel])
                #expect(abs(value - expected) < 2e-4,
                        "code \(code): shader \(value), Apple Log 2 says \(expected)")
            }
        }
    }

    /// The two segments meet without a step. A wrong join shows up as a jump in the identity
    /// map across `P_t`.
    @Test func decodeAndEncodeJoinContinuouslyAtTheToe() throws {
        // The published constants are rounded to eight decimals, so the joint closes to about
        // 6e-5 rather than exactly; that is the source's own precision, not a stride.
        #expect(abs(AppleLog2.decode(AppleLog2.pt) - AppleLog2.rt) < 1e-4)
        #expect(abs(AppleLog2.encode(AppleLog2.rt) - AppleLog2.pt) < 1e-4)

        let step: Float = 0.002
        var codes = [Float]()
        var code: Float = 0.15
        while code <= 0.27 {
            codes.append(code)
            code += step
        }
        let rendered = try render(codes, whiteBalance: matrix_identity_float3x3)
        for index in 1..<rendered.count {
            let jump = abs(rendered[index][0] - rendered[index - 1][0])
            #expect(jump < step * 2 + 1e-4,
                    "step across the join at \(codes[index]) jumped by \(jump)")
        }
    }

    /// White-balance direction, measured on real renders of a neutral plate: a daylight scene
    /// under a tungsten lock reads blue, and a tungsten scene under a daylight lock reads warm.
    @Test func whiteBalanceCastsTowardTheSceneIlluminant() throws {
        let neutral: [Float] = [0.488]
        let daylightSceneTungstenLock = try render(
            neutral, whiteBalance: PlateWhiteBalance.adaptation(sceneKelvin: 5600, lockedKelvin: 3200))
        let blue = daylightSceneTungstenLock[0]
        #expect(blue[2] > blue[1] && blue[1] > blue[0],
                "a 5600 K scene on a 3200 K lock must read blue, got \(blue)")

        let tungstenSceneDaylightLock = try render(
            neutral, whiteBalance: PlateWhiteBalance.adaptation(sceneKelvin: 3200, lockedKelvin: 5600))
        let warm = tungstenSceneDaylightLock[0]
        #expect(warm[0] > warm[1] && warm[1] > warm[2],
                "a 3200 K scene on a 5600 K lock must read warm, got \(warm)")

        let matched = try render(
            neutral, whiteBalance: PlateWhiteBalance.adaptation(sceneKelvin: 5600, lockedKelvin: 5600))
        for channel in 0..<3 {
            #expect(abs(matched[0][channel] - 0.488) < 1e-4, "a matched lock must not tint")
        }
    }

    /// The adaptation must be a full Bradford transform in Apple Wide Gamut -- it carries the
    /// locked white onto the scene white in that basis. A diagonal derived in sRGB and applied
    /// to Apple Wide Gamut values is both the wrong basis and the wrong magnitude.
    @Test func adaptationIsAFullTransformInAppleWideGamutNotAnSRGBDiagonal() throws {
        let xyzToAppleWideGamut = try #require(
            AppleLog2.primariesMatrix(red: SIMD2(0.725, 0.301),
                                      green: SIMD2(0.221, 0.814),
                                      blue: SIMD2(0.068, -0.076),
                                      white: SIMD2(0.3127, 0.3290)).inverse)

        let transform = PlateWhiteBalance.adaptation(sceneKelvin: 5600, lockedKelvin: 3200)
        // It maps the locked illuminant's white to the scene illuminant's white, in AppleWG.
        let lockedWhite = xyzToAppleWideGamut * AppleLog2.planckianXYZ(3200)
        let sceneWhite = xyzToAppleWideGamut * AppleLog2.planckianXYZ(5600)
        let mapped = AppleLog2.normalise(transform * lockedWhite)
        let expected = AppleLog2.normalise(sceneWhite)
        for channel in 0..<3 {
            #expect(abs(mapped[channel] - expected[channel]) < 1e-4,
                    "the transform must move the 3200 K white onto the 5600 K white in AppleWG")
        }
        // A full matrix, not a per-channel gain.
        #expect(abs(transform.columns.1.x) > 0.05,
                "a diagonal transform would have no green-into-red term")
        // And the neutral cast is the AppleWG-basis one, not the sRGB diagonal's (~0.46 red).
        let cast = transform * SIMD3<Float>(repeating: 1)
        #expect(abs(cast.x - 0.845) < 0.02, "red gain should be AppleWG's, got \(cast.x)")
        #expect(abs(cast.z - 2.047) < 0.05, "blue gain should be AppleWG's, got \(cast.z)")
        #expect(cast.x > 0.6, "the sRGB diagonal's 0.46 red is the wrong basis")

        #expect(matrixApproximatelyEqual(PlateWhiteBalance.adaptation(sceneKelvin: 5600, lockedKelvin: 5600),
                                        matrix_identity_float3x3))
    }
}

/// The Apple Log 2 reference curve and Apple Wide Gamut primaries, as published in the Apple
/// Log 2 white paper and copied into OpenColorIO 2.6 `AppleCameras.cpp`.
private enum AppleLog2 {
    static let r0 = -0.05641088
    static let rt = 0.01
    static let c = 47.28711236
    static let beta = 0.00964052
    static let gamma = 0.08550479
    static let delta = 0.69336945
    /// The join of the two segments: the toe is a square root of the code, so the break is at
    /// the code `c*(R_t - R_0)^2`, not the linear toe's `(R_t - R_0)/c`.
    static let pt = c * (rt - r0) * (rt - r0)

    static func decode(_ code: Double) -> Double {
        if code >= pt { return pow(2, (code - delta) / gamma) - beta }
        if code >= 0 { return (code / c).squareRoot() + r0 }
        return r0
    }

    static func encode(_ linear: Double) -> Double {
        if linear <= r0 { return 0 }
        return linear < rt ? c * (linear - r0) * (linear - r0) : delta + gamma * log2(linear + beta)
    }

    static func planckianXYZ(_ kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 1667), 25000)
        let x: Float = t <= 4000
            ? -0.2661239e9 / pow(t, 3) - 0.2343589e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390
        let y: Float
        if t <= 2222 {
            y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2) + 3.75112997 * x - 0.37001483
        }
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    static func primariesMatrix(red: SIMD2<Float>, green: SIMD2<Float>,
                                blue: SIMD2<Float>, white: SIMD2<Float>) -> simd_float3x3 {
        func toXYZ(_ chromaticity: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(chromaticity.x / chromaticity.y, 1,
                  (1 - chromaticity.x - chromaticity.y) / chromaticity.y)
        }
        let primaries = simd_float3x3(toXYZ(red), toXYZ(green), toXYZ(blue))
        return primaries * simd_float3x3(diagonal: primaries.inverse * toXYZ(white))
    }

    static func normalise(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let sum = v.x + v.y + v.z
        return sum == 0 ? v : v / sum
    }
}

/// Two 3x3 matrices agree to within a tolerance.
private func matrixApproximatelyEqual(_ lhs: simd_float3x3, _ rhs: simd_float3x3) -> Bool {
    let difference = lhs - rhs
    let columns = [difference.columns.0, difference.columns.1, difference.columns.2]
    return columns.allSatisfy { abs($0.x) < 1e-6 && abs($0.y) < 1e-6 && abs($0.z) < 1e-6 }
}
