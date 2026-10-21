import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation
import Testing
import VideoToolbox

/// Native export integration for the daylight-60fps mode. Exercises a short
/// synthetic 60 fps clip through the real Metal renderer and asserts the output
/// keeps real 60 fps cadence, its frame count, its audio track, and the
/// policy-driven metadata — not just a source-string wiring check.
///
/// Grain pairing (`pairedAtHalfRate`) is a grain *index* decision proven by
/// `GrainPairingPolicyTests`; this suite proves the transport stayed 60 fps and
/// that metadata carries the mode.
@Suite(.serialized)
struct DaylightExportIntegrationTests {
    private enum FixtureError: Error {
        case writerStart(Error?)
        case audioFormat(OSStatus)
        case sampleBuffer(OSStatus)
    }

    private final class BundleToken {}

    @Test(.timeLimit(.minutes(1)))
    func sixtyFpsSourceExportsSixtyFpsOutputWithPolicyMetadataAndAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source60.mov")
        let frameCount = 24
        try await makeSixtyFpsFixture(at: source, videoFrameCount: frameCount, audioSampleCount: 48)
        let sourceData = try Data(contentsOf: source)

        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let policy = try #require(RenderCapturePolicy(60))
        let output = try await renderer.render(sourceURL: source, config: loadConfig(),
                                               bitrate: 2_000_000, capturePolicy: policy)
        defer { try? FileManager.default.removeItem(at: output) }

        // The source is untouched.
        #expect(try Data(contentsOf: source) == sourceData)

        let outputAsset = AVURLAsset(url: output)
        let tracks = try await outputAsset.load(.tracks)
        let videoTrack = try #require(tracks.first(where: { $0.mediaType == .video }))
        #expect(tracks.contains(where: { $0.mediaType == .audio }))
        #expect(try Self.audioPackets(of: output) == Self.audioPackets(of: source))

        // 60 fps cadence: read every video sample and measure the mean step.
        let sourceTimes = try Self.presentationTimes(of: source)
        let outputTimes = try Self.presentationTimes(of: output)
        // The renderer copies the source PTS verbatim — no retiming, no dropped
        // or doubled frames. Motion transport is preserved 1:1.
        #expect(sourceTimes.count == frameCount)
        #expect(outputTimes.count == sourceTimes.count, "src=\(sourceTimes.count) out=\(outputTimes.count)")
        // Same set of presentation times: no retiming, no dropped or doubled
        // frames. (Sample *order* differs because the HEVC output is stored in
        // decode order; the presentation instants are identical.)
        let sourceSet = sourceTimes.filter { $0.isFinite }.sorted()
        let outputSet = outputTimes.filter { $0.isFinite }.sorted()
        #expect(outputSet == sourceSet, "PTS transport changed")
        // Cadence: the smallest positive step between distinct finite frame times
        // is one 1/60 s tick (30 Hz grain pairing does not retime motion).
        let finite = outputTimes.filter { $0.isFinite }.sorted()
        let positiveSteps = zip(finite.dropFirst(), finite).map { $0 - $1 }.filter { $0 > 1e-6 }
        let minStep = positiveSteps.min() ?? .nan
        #expect(abs(minStep - (1.0 / 60.0)) < 0.001, "minStep=\(minStep) finiteCount=\(finite.count)")
        // The track advertises ~60 fps.
        let nominal = try await videoTrack.load(.nominalFrameRate)
        #expect(abs(Double(nominal) - 60) < 1.0, "nominal=\(nominal)")

        // Metadata carries the mode from the persisted policy.
        var values: [String: String] = [:]
        for item in try await outputAsset.load(.metadata) {
            if let key = item.key as? String, let value = try await item.load(.stringValue) {
                values[key] = value
            }
        }
        #expect(values["com.filmemulation.shutter-speed"] == "1/120")
        #expect(values["com.filmemulation.shutter-angle"] == "180")
        #expect(values["com.filmemulation.capture-frame-rate"] == "60")
        #expect(values["com.filmemulation.source-color-test-bypass"] == "true")
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyNilPolicyExportsOneFortyEightMetadataAtSourceCadence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source24.mov")
        try await makeSixtyFpsFixture(at: source, videoFrameCount: 12, audioSampleCount: 48)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let output = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000)
        defer { try? FileManager.default.removeItem(at: output) }

        var values: [String: String] = [:]
        for item in try await AVURLAsset(url: output).load(.metadata) {
            if let key = item.key as? String, let value = try await item.load(.stringValue) {
                values[key] = value
            }
        }
        #expect(values["com.filmemulation.shutter-speed"] == "1/48")
        // Legacy output must not gain the new provenance key (byte-for-byte ethos).
        #expect(values["com.filmemulation.capture-frame-rate"] == nil)
    }

    // MARK: - Fixtures

    private func makeSixtyFpsFixture(at url: URL, videoFrameCount: Int, audioSampleCount: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        // Intra-frame codec: no B-frame reordering, so every sample carries a
        // finite, presentation-ordered PTS the cadence check can measure.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422LT,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var audioDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &audioDescription)
        guard formatStatus == noErr, let audioDescription else { throw FixtureError.audioFormat(formatStatus) }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ], sourceFormatHint: audioDescription)

        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw FixtureError.writerStart(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "daylight-fixture-audio")) {
            do {
                for index in 0..<audioSampleCount {
                    while !audioInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                    let sample = try Self.pcmSample(format: audioDescription, index: index)
                    guard audioInput.append(sample) else { throw writer.error ?? FixtureError.writerStart(nil) }
                }
                audioInput.markAsFinished()
            } catch { writer.cancelWriting() }
            group.leave()
        }
        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "daylight-fixture-video")) {
            do {
                for index in 0..<videoFrameCount {
                    while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                    var pixelBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                                    adaptor.pixelBufferPool!, &pixelBuffer)
                    guard status == kCVReturnSuccess, let pixelBuffer else {
                        throw FixtureError.writerStart(writer.error)
                    }
                    // Deterministic nonblank, moving input, never uninitialized pool memory.
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                        for row in 0..<64 {
                            let bytes = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                            for column in 0..<64 {
                                bytes[column * 4] = UInt8((column + index) % 128 + 64)
                                bytes[column * 4 + 1] = UInt8(row + 64)
                                bytes[column * 4 + 2] = 128
                                bytes[column * 4 + 3] = 255
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    // 60 fps cadence: PTS in 1/60 s ticks.
                    guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 60)) else {
                        throw writer.error ?? FixtureError.writerStart(nil)
                    }
                }
                videoInput.markAsFinished()
            } catch { writer.cancelWriting() }
            group.leave()
        }
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: group.wait(timeout: .now() + 15) == .success)
            }
        }
        guard finished else { writer.cancelWriting(); throw FixtureError.writerStart(writer.error) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.writerStart(writer.error) }
    }

    private static func pcmSample(format: CMAudioFormatDescription, index: Int) throws -> CMSampleBuffer {
        let frameCount = 1024
        var pcm = (0..<frameCount).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(index * frameCount + frame) / 48_000)) * 0.1
        }
        var blockBuffer: CMBlockBuffer?
        let byteCount = pcm.count * MemoryLayout<Float>.size
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { throw FixtureError.sampleBuffer(blockStatus) }
        let replaceStatus = pcm.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { throw FixtureError.sampleBuffer(replaceStatus) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(index * frameCount), timescale: 48_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw FixtureError.sampleBuffer(status) }
        return sample
    }

    private static func presentationTimes(of url: URL) throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first
        guard let track else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return [] }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        #expect(reader.status == .completed)
        reader.cancelReading()
        return times
    }

    private static func audioPackets(of url: URL) throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var packets: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            // AVAssetReader can also emit zero-payload timing/trim marker samples.
            guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                           destination: bytes.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            packets.append(data)
        }
        #expect(reader.status == .completed)
        #expect(!packets.isEmpty)
        return packets
    }

    private var testBundle: Bundle { Bundle(for: BundleToken.self) }

    private func loadConfig() throws -> FilmStockConfig {
        let configURL = testBundle.url(forResource: "stocks", withExtension: "json")
            ?? TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        let container = try JSONDecoder().decode(StockContainer.self, from: Data(contentsOf: configURL))
        return try #require(container.stocks.first { $0.stockId == "kodak5219" })
    }

    private struct StockContainer: Decodable { let stocks: [FilmStockConfig] }
}
