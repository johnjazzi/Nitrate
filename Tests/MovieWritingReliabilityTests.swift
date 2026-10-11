import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation
import Testing

@Suite(.serialized)
struct MovieWritingReliabilityTests {
    private enum FixtureError: Error {
        case writerStart(Error?)
        case audioFormat(OSStatus)
        case sampleBuffer(OSStatus)
        case missingResource(String)
    }

    private final class BundleToken {}

    @Test func trimmedRenderRetainsAudioAndStartsAtZero() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let originalSourceData = try Data(contentsOf: source)
        let config = try loadConfig()

        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let trim = CMTimeRange(start: CMTime(value: 2, timescale: 10), duration: CMTime(value: 4, timescale: 10))
        let output = try await renderer.render(sourceURL: source, config: config, trimRange: trim, bitrate: 2_000_000)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputAsset = AVURLAsset(url: output)
        let tracks = try await outputAsset.load(.tracks)
        #expect(tracks.contains(where: { $0.mediaType == .video }))
        #expect(tracks.contains(where: { $0.mediaType == .audio }))
        let duration = try await outputAsset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 0.25)
        #expect(CMTimeGetSeconds(duration) < 0.55)
        #expect(try Data(contentsOf: source) == originalSourceData)
        let videoTrack = try #require(tracks.first(where: { $0.mediaType == .video }))
        let reader = try AVAssetReader(asset: outputAsset)
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(trackOutput)
        #expect(reader.startReading())
        let firstSample = try #require(trackOutput.copyNextSampleBuffer())
        #expect(abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(firstSample))) < 0.001)
        #expect(reader.status == .reading || reader.status == .completed)

        let audioTrack = try #require(tracks.first(where: { $0.mediaType == .audio }))
        let audioReader = try AVAssetReader(asset: outputAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioReader.add(audioOutput)
        #expect(audioReader.startReading())
        let firstAudioSample = try #require(audioOutput.copyNextSampleBuffer())
        #expect(abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(firstAudioSample))) < 0.03)
        let audioDuration = CMTimeGetSeconds(audioTrack.timeRange.duration)
        #expect(audioDuration > 0.35)
        #expect(audioDuration < 0.45)
    }

    @Test func renderFailureAfterEncodedFramesRemovesPartialAndPreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let originalSourceData = try Data(contentsOf: source)
        let config = try loadConfig()
        let renderer = try PipelineRenderer(
            resourceBundle: testBundle,
            renderFailureAfterFrames: 2,
            outputDirectory: directory
        )

        do {
            _ = try await renderer.render(sourceURL: source, config: config, bitrate: 2_000_000)
            Issue.record("Synthetic frame failure unexpectedly completed")
        } catch {
            #expect(error.localizedDescription.contains("injected-frame-failure"))
        }
        #expect(try Data(contentsOf: source) == originalSourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    @Test func longerAudioContinuesAfterVideoEOF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source, videoFrameCount: 3, audioSampleCount: 64)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let output = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000)
        defer { try? FileManager.default.removeItem(at: output) }

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        let video = try #require(tracks.first(where: { $0.mediaType == .video }))
        let audio = try #require(tracks.first(where: { $0.mediaType == .audio }))
        #expect(CMTimeGetSeconds(audio.timeRange.duration) > CMTimeGetSeconds(video.timeRange.duration) + 0.5)
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test func silentClipRendersWithoutAudioTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source, videoFrameCount: 4, hasAudio: false)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let output = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000)
        defer { try? FileManager.default.removeItem(at: output) }

        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.contains(where: { $0.mediaType == .video }))
        #expect(!tracks.contains(where: { $0.mediaType == .audio }))
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test func audioAppendFailureCancelsRenderAndRemovesPartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(
            resourceBundle: testBundle,
            audioAppendRejectionAfterSamples: 1,
            outputDirectory: directory
        )

        do {
            _ = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000)
            Issue.record("Synthetic audio append rejection unexpectedly completed")
        } catch {
            #expect(error.localizedDescription.contains("audio-append"))
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    @Test func cancelledBeforeRenderStartsLeavesSourceAndNoOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let config = try loadConfig()
        let task = Task { try await renderer.render(sourceURL: source, config: config, bitrate: 2_000_000) }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A pre-cancelled render unexpectedly completed")
        } catch is CancellationError {
            #expect(true)
        } catch {
            Issue.record("Expected cancellation, received: \(error.localizedDescription)")
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    @Test func cancelledDuringRenderingRemovesPartialAndPreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source, videoFrameCount: 60, audioSampleCount: 64)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let config = try loadConfig()
        let task = Task { try await renderer.render(sourceURL: source, config: config, bitrate: 2_000_000) }
        var observedPartialOutput = false
        for _ in 0..<500 {
            let outputFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            if let partial = outputFiles.first(where: { $0.lastPathComponent.hasPrefix("render_") }),
               let fileSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > 0 {
                observedPartialOutput = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedPartialOutput)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled in-flight render unexpectedly completed")
        } catch {
            #expect(error is CancellationError || error.localizedDescription.contains("writer"))
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    @Test func emptyTrimFailsAtVideoEOFAndRemovesOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let emptyTrim = CMTimeRange(start: CMTime(value: 5, timescale: 1), duration: CMTime(value: 1, timescale: 10))

        do {
            _ = try await renderer.render(sourceURL: source, config: loadConfig(), trimRange: emptyTrim, bitrate: 2_000_000)
            Issue.record("An empty trim unexpectedly completed")
        } catch {
            #expect(error.localizedDescription.contains("reader") || error.localizedDescription.contains("video"))
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    private func makeFixture(
        at url: URL,
        videoFrameCount: Int = 10,
        audioSampleCount: Int = 48,
        hasAudio: Bool = true
    ) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var audioDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &audioDescription
        )
        guard formatStatus == noErr, let audioDescription else { throw FixtureError.audioFormat(formatStatus) }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ], sourceFormatHint: audioDescription)
        writer.add(videoInput)
        if hasAudio { writer.add(audioInput) }
        guard writer.startWriting() else { throw FixtureError.writerStart(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let inputsDone = DispatchGroup()
        let failure = FixtureFailureBox()
        inputsDone.enter()
        if hasAudio {
            inputsDone.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "movie-fixture-audio")) {
            do {
                let deadline = Date().addingTimeInterval(10)
                for index in 0..<audioSampleCount {
                    while !audioInput.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                    guard audioInput.isReadyForMoreMediaData else { throw FixtureError.writerStart(writer.error) }
                    let sample = try Self.pcmSample(format: audioDescription, index: index)
                    guard audioInput.append(sample) else { throw writer.error ?? FixtureError.writerStart(nil) }
                }
                audioInput.markAsFinished()
            } catch {
                failure.set(error)
                writer.cancelWriting()
            }
            inputsDone.leave()
            }
        }
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "movie-fixture-video")) {
            do {
                let deadline = Date().addingTimeInterval(10)
                for index in 0..<videoFrameCount {
                    while !videoInput.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                    guard videoInput.isReadyForMoreMediaData else { throw FixtureError.writerStart(writer.error) }
                    var pixelBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pixelBuffer)
                    guard status == kCVReturnSuccess, let pixelBuffer else { throw FixtureError.writerStart(writer.error) }
                    guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                        throw writer.error ?? FixtureError.writerStart(nil)
                    }
                }
                videoInput.markAsFinished()
            } catch {
                failure.set(error)
                writer.cancelWriting()
            }
            inputsDone.leave()
        }
        let inputsFinished = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: inputsDone.wait(timeout: .now() + 15) == .success)
            }
        }
        guard inputsFinished else {
            writer.cancelWriting()
            throw FixtureError.writerStart(writer.error)
        }
        if let error = failure.error { throw error }
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
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { throw FixtureError.sampleBuffer(blockStatus) }
        let replaceStatus = pcm.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { throw FixtureError.sampleBuffer(replaceStatus) }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(index * frameCount), timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw FixtureError.sampleBuffer(status) }
        return sample
    }

    private var testBundle: Bundle { Bundle(for: BundleToken.self) }

    private func loadConfig() throws -> FilmStockConfig {
        let configURL = testBundle.url(forResource: "stocks", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App/Resources/stocks.json").standardizedFileURL
        let stockContainer = try JSONDecoder().decode(StockContainer.self, from: Data(contentsOf: configURL))
        guard let config = stockContainer.stocks.first(where: { $0.stockId == "kodak500t_k2383" }) else {
            throw FixtureError.missingResource("kodak500t_k2383 stock configuration")
        }
        return config
    }

    private final class FixtureFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        func set(_ error: Error) {
            lock.lock()
            storedError = error
            lock.unlock()
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
    }

    private struct StockContainer: Decodable { let stocks: [FilmStockConfig] }
}
