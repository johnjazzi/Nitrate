import CoreImage
import CoreVideo
import ImageIO
import Foundation
import Testing
import UniformTypeIdentifiers
import simd

/// Resource-free pixel regressions for the boundaries around the video Debug renderer.
/// These do not establish RAW Photo replay or capture/white-balance equivalence.
@Suite struct DebugFrameColorAdapterTests {
    private let width = 17
    private let height = 9
    private var linearSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

    private func ramp(_ x: Int, _ y: Int) -> SIMD3<Double> {
        SIMD3(0.08 + 0.77 * Double(x) / Double(width - 1),
              0.14 + 0.57 * Double(y) / Double(height - 1),
              0.11 + 0.63 * Double(x + 2 * y) / Double(width + 2 * height - 3))
    }

    private func halfRamp() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let result = try #require(buffer)
        #expect(CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(result))
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                let rgb = ramp(x, y)
                for c in 0..<3 { row[x * 4 + c] = Float16(rgb[c]) }
                row[x * 4 + 3] = 1
            }
        }
        return result
    }

    private func halfPixels(_ buffer: CVPixelBuffer) throws -> [SIMD3<Double>] {
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf)
        #expect(CVPixelBufferGetWidth(buffer) == width)
        #expect(CVPixelBufferGetHeight(buffer) == height)
        #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        return (0..<height).flatMap { y in
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float16.self)
            return (0..<width).map { x in SIMD3(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2])) }
        }
    }

    private func decodeSRGB(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @Test func sdrHalfStorageMustNotBypassTheInputTransform() throws {
        let source = try halfRamp()
        let original = try halfPixels(source)
        for domain in [DebugFrameSourceAdapter.SourceColorSpace.sRGB, .displayP3] {
            let output = try #require(DebugFrameSourceAdapter.rgbaHalfBuffer(from: source, sourceColorSpace: domain))
            let actual = try halfPixels(output)
            var maximumError = 0.0
            var unconvertedError = 0.0
            for i in original.indices {
                let code = original[i]
                var linear = SIMD3(decodeSRGB(code.x), decodeSRGB(code.y), decodeSRGB(code.z))
                if domain == .displayP3 {
                    // Independent D65 Display-P3 -> linear-sRGB reference; extended values must survive.
                    linear = simd_double3x3(rows: [
                        SIMD3(1.224940176, -0.224940176, 0),
                        SIMD3(-0.042056955, 1.042056955, 0),
                        SIMD3(-0.019637555, -0.078636046, 1.098273601)
                    ]) * linear
                }
                let expected = try RAWToLog2Stage.apply(linear).appleLog2
                for c in 0..<3 {
                    maximumError = max(maximumError, abs(actual[i][c] - expected[c]))
                    unconvertedError = max(unconvertedError, abs(code[c] - expected[c]))
                    #expect(actual[i][c].isFinite && actual[i][c] >= 0 && actual[i][c] <= 1)
                }
            }
            #expect(maximumError < 0.004, "SDR must decode and transform before the existing Log renderer: \(maximumError)")
            #expect(unconvertedError > 0.1, "The old storage-only adapter must fail this asymmetric ramp")
            #expect(abs(actual.first!.x - actual.last!.x) > 0.1, "A constant/collapsed image is not a passing transform")
        }
    }

    @Test func explicitSourceOverridesUnrelatedBufferColorTags() throws {
        let source = try halfRamp()
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey,
            CGColorSpace(name: CGColorSpace.displayP3)!, .shouldPropagate)
        let converted = try #require(DebugFrameSourceAdapter.rgbaHalfBuffer(from: source, sourceColorSpace: .sRGB))
        let actual = try halfPixels(converted)
        let original = try halfPixels(source)
        let code = original[width + 3]
        let expected = try RAWToLog2Stage.apply(SIMD3(decodeSRGB(code.x), decodeSRGB(code.y), decodeSRGB(code.z))).appleLog2
        for c in 0..<3 { #expect(abs(actual[width + 3][c] - expected[c]) < 0.004) }
    }

    @Test func logHalfSourceKeepsItsExactCodeValues() throws {
        let source = try halfRamp()
        let output = try #require(DebugFrameSourceAdapter.rgbaHalfBuffer(from: source, sourceColorSpace: .appleLog2))
        let before = try halfPixels(source)
        let after = try halfPixels(output)
        let identical = before == after
        #expect(identical, "Log must not receive SDR decoding or a second Log encoding")
    }

    @Test func debugSheetDisclosesProcessedSnapshotAndUsesExplicitDisplayConversion() throws {
        let sheet = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/DebugFrameSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("Frozen processed-camera frame"))
        #expect(sheet.contains("not a delivered RAW Photo replay"))
        #expect(sheet.contains("White balance and ISP processing are frozen"))
        #expect(sheet.contains("FilmOutputDisplayConverter.makeSRGBImage"))
        #expect(!sheet.contains("CGColorSpaceCreateDeviceRGB"))
        #expect(!sheet.contains("stock's shipping look"))
        let capture = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "App/Modules/CameraCapture/DebugFrameCapture.swift"), encoding: .utf8)
        #expect(capture.contains("sourceColorSpace: AVCaptureColorSpace = .appleLog2"))
        #expect(capture.contains("default: return nil"), "Unknown/HDR/Apple Log 1 sources must not be guessed")
    }

    @Test func displayGammaDecodeMatchesIndependentReferenceAndJPEG() throws {
        // Values here are final gamma-2.4 LUT output, not linear scene samples.
        let source = try halfRamp()
        let gammaPixels = try halfPixels(source)
        let image = CIImage(cvPixelBuffer: source, options: [.colorSpace: linearSpace])
        let display = try FilmOutputDisplayConverter.makeSRGBImage(fromGamma24: image)
        #expect(display.colorSpace?.name == CGColorSpace.sRGB)
        let context = CIContext(options: [.workingColorSpace: linearSpace])
        func bytes(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &result, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return result
        }
        let actual = bytes(CIImage(cgImage: display))
        let omittedDecode = bytes(image)
        var maxError = 0.0
        var negativeControlError = 0.0
        for i in gammaPixels.indices {
            for c in 0..<3 {
                let linear = pow(gammaPixels[i][c], 2.4)
                let expected = (linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055) * 255
                maxError = max(maxError, abs(Double(actual[i * 4 + c]) - expected))
                negativeControlError = max(negativeControlError, abs(Double(omittedDecode[i * 4 + c]) - expected))
            }
        }
        #expect(maxError <= 2, "Display must apply gamma-2.4 decode before sRGB encode: \(maxError)")
        #expect(negativeControlError > 30, "Omitting gamma decode must fail visibly")
        #expect(Set(actual).count > 30, "A collapsed/white output is not a valid display conversion")
        // Real JPEG round trip of the very same float output; no DNG or stock resources needed.
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, display,
            [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decodedSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        let jpeg = bytes(CIImage(cgImage: decoded))
        let differences = actual.indices.filter { $0 % 4 != 3 }.map { abs(Int(actual[$0]) - Int(jpeg[$0])) }
        let meanError = Double(differences.reduce(0, +)) / Double(differences.count)
        #expect(meanError < 6, "JPEG and Debug must share delivery-color interpretation, allowing chroma/quantization loss: \(meanError)")
    }
}
