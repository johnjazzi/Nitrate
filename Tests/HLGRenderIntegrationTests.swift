import AVFoundation
import CoreVideo
import Foundation
import Metal
import Testing
import VideoToolbox

/// Coordinator-run integration coverage. Synthetic source pixels are explicitly
/// tagged native HLG; no renderer contract bypass is enabled.
struct HLGRenderIntegrationTests {
    private final class BundleToken {}
    private struct Stocks: Decodable { let stocks: [FilmStockConfig] }

    private func frame(width: Int = 1920, height: Int = 1440,
                       profile: CameraSourceProfile = .hlgBT2020, ramp: Bool = false) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                    attributes as CFDictionary, &optional) == kCVReturnSuccess)
        let buffer = try #require(optional)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let words = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                // HLG code .75, neutral chroma. Initialize even row padding.
                for column in 0..<(stride / 2) {
                    let luma = ramp ? 64 + 876 * min(column, width - 1) / max(width - 1, 1) : 721
                    words[column] = UInt16(plane == 0 ? luma : 512) << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if profile == .hlgBT2020 {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        } else if #available(iOS 26.0, macOS 26.0, *) {
            CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog2, .shouldPropagate)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private func sample(_ frame: CVPixelBuffer, index: Int64) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame,
                                                           formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: CMTime(value: index, timescale: 24), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame,
            formatDescription: try #require(description), sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func config() throws -> FilmStockConfig {
        let stocks = try JSONDecoder().decode(Stocks.self, from: Data(contentsOf:
            TestRepository.root.appendingPathComponent("App/Resources/stocks.json")))
        return try #require(stocks.stocks.first { $0.stockId == "kodak5219" })
    }

    @Test(.timeLimit(.minutes(1)))
    func frozenHLGUsesActualFilmPipelineAndKeepsSourceEvidence() throws {
        let frame = try frame(width: 64, height: 64, ramp: true)
        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self))
        let config = try config()
        var parameters = PipelineRenderer.DebugFrameParameters(config: config)
        parameters.halationStrength = 0
        parameters.glowStrength = 0
        parameters.presenceMultiplier = 0
        let result = try #require(renderer.renderDebugFrame(pixelBuffer: frame, config: config, parameters: parameters))
        #expect(result.width == 64)
        #expect(result.height == 64)
        #expect(CVPixelBufferGetPixelFormatType(result.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferLockBaseAddress(result.pixelBuffer, .readOnly) == kCVReturnSuccess)
        let base = try #require(CVPixelBufferGetBaseAddress(result.pixelBuffer))
        let row = base.advanced(by: 32 * CVPixelBufferGetBytesPerRow(result.pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        // A blank/constant placeholder must not pass the render smoke.
        let left = Int(row[8 * 4]) + Int(row[8 * 4 + 1]) + Int(row[8 * 4 + 2])
        let right = Int(row[55 * 4]) + Int(row[55 * 4 + 1]) + Int(row[55 * 4 + 2])
        CVPixelBufferUnlockBaseAddress(result.pixelBuffer, .readOnly)
        #expect(right - left > 120)
        #expect(RenderInputColorProvenance.profile(of: frame) == .hlgBT2020)
        // Unknown source tags are never silently interpreted as Log 2.
        CVBufferRemoveAttachment(frame, kCVImageBufferTransferFunctionKey)
        #expect(renderer.renderDebugFrame(pixelBuffer: frame, config: config, parameters: parameters) == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CameraSourceProfile.hlgBT2020, .appleLog2])
    func productionRecorderAndVideoRenderPreserveOriginalAndDeliverSDR(profile: CameraSourceProfile) async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.mov")
        let recorder = CameraSampleBufferRecorder(queue: DispatchQueue(label: "hlg.integration.recorder"))
        let tags = CameraSampleValidationPolicy.originalColorProperties(for: profile)
        let geometry: CaptureFormat = profile == .appleLog2 ? .uhd16x9 : .openGate2K
        let settings = CameraSampleValidationPolicy.explicitHEVCMain10Settings(width: Int(geometry.width), height: Int(geometry.height),
            profile: kVTProfileLevel_HEVC_Main10_AutoLevel as String, averageBitRate: 10_000_000, colorProperties: tags)
        let pixels = try frame(width: Int(geometry.width), height: Int(geometry.height), profile: profile)
        let first = try sample(pixels, index: 0)
        let second = try sample(pixels, index: 1)
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            recorder.begin(to: url, videoSettings: settings, audioSettings: nil,
                acceptedPixelFormats: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
                sourceProfile: profile, metadata: [], onStarted: { _ in },
                onFinished: { continuation.resume(returning: $0) })
            recorder.submitVideoSampleForTesting(first)
            recorder.submitVideoSampleForTesting(second)
            recorder.stop()
        }
        let original = try result.get()
        let sourceTrack = try #require(try await AVURLAsset(url: original).loadTracks(withMediaType: .video).first)
        let descriptions = try await sourceTrack.load(.formatDescriptions)
        let provenance = try RenderInputColorProvenance.inspect(descriptions, expectedProfile: profile)
        #expect(provenance.expected == profile.label)
        #expect(provenance.formatDescriptions.allSatisfy { $0.bitDepth == "10" && $0.codec == "hvc1" })
        if profile == .hlgBT2020 {
            #expect(throws: RenderInputColorContractError.self) {
                _ = try RenderInputColorProvenance.inspect(descriptions)
            }
        }
        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self), outputDirectory: directory)
        let output = try await renderer.render(sourceURL: original, config: config(), bitrate: 2_000_000,
                                               capturePolicy: RenderCapturePolicy(24, sourceProfile: profile))
        let outputTrack = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        for description in try await outputTrack.load(.formatDescriptions) {
            let evidence = RenderInputColorProvenance.evidence(for: description)
            #expect(evidence.logTransferFunction == nil)
            #expect(evidence.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
            #expect(evidence.transferFunction == AVVideoTransferFunction_ITU_R_709_2)
        }
        // Re-read retained original after the render: no relabeling into LUT domain.
        _ = try RenderInputColorProvenance.inspect(try await sourceTrack.load(.formatDescriptions), expectedProfile: profile)
    }
}
