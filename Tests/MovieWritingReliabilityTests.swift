import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation
import Testing
import VideoToolbox

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

        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
        var outputMetadata: [String: String] = [:]
        for item in try await outputAsset.load(.metadata) {
            if let key = item.key as? String, let value = try await item.load(.stringValue) { outputMetadata[key] = value }
        }
        #expect(outputMetadata["com.filmemulation.source-color-test-bypass"] == "true")
        #expect(outputMetadata["com.filmemulation.capture-color-space"] == "unknown-or-not-recorded")
        let sourceColorJSON = try #require(outputMetadata["com.filmemulation.source-color-provenance"])
        let sourceColor = try JSONDecoder().decode(RenderInputColorProvenance.self, from: Data(sourceColorJSON.utf8))
        #expect(sourceColor.validationStatus == "explicit-synthetic-test-bypass")
        #expect(sourceColor.formatDescriptions.count == 1)
        #expect(sourceColor.formatDescriptions[0].logTransferFunction == nil)
        let settingsJSON = try #require(outputMetadata["com.filmemulation.render-settings"])
        let settings = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self, from: Data(settingsJSON.utf8))
        #expect(settings.sourceColorProvenance == sourceColor)

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

    @Test(arguments: RenderExportQuality.allCases)
    func exportQualitiesProduceReadableHEVCWithoutChangingSource(quality: RenderExportQuality) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let output = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: quality.averageBitRate)
        let sourceAsset = AVURLAsset(url: source)
        let outputAsset = AVURLAsset(url: output)
        let sourceVideo = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let outputVideo = try #require(try await outputAsset.loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceVideo.load(.naturalSize)
        let outputSize = try await outputVideo.load(.naturalSize)
        let sourceRate = try await sourceVideo.load(.nominalFrameRate)
        let outputRate = try await outputVideo.load(.nominalFrameRate)
        #expect(outputSize == sourceSize)
        #expect(abs(outputRate - sourceRate) < 0.01)
        #expect(try await outputAsset.loadTracks(withMediaType: .audio).count == 1)
        let descriptions = try await outputVideo.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        var settingsJSON: String?
        for item in try await outputAsset.load(.metadata) {
            if item.key as? String == "com.filmemulation.render-settings" {
                settingsJSON = try await item.load(.stringValue)
            }
        }
        let settings = try JSONDecoder().decode(RenderDiagnosticsManifest.RecipeSnapshot.self,
                                                 from: Data(try #require(settingsJSON).utf8))
        #expect(settings.averageBitRate == quality.averageBitRate)
        let reader = try AVAssetReader(asset: outputAsset)
        let decoded = AVAssetReaderTrackOutput(track: outputVideo,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded)
        #expect(reader.startReading())
        let frame = try #require(decoded.copyNextSampleBuffer())
        #expect(CMSampleBufferGetImageBuffer(frame) != nil)
        reader.cancelReading()
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test func defaultRendererRejectsUntaggedSyntheticInputBeforeOutputCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeFixture(at: source, hasAudio: false, claimedCaptureColorSpace: "Apple Log 2")
        let metadata = try await AVURLAsset(url: source).load(.metadata)
        let captureItem = try #require(metadata.first { ($0.key as? String) == "com.filmemulation.capture-color-space" })
        let captureClaim = try await captureItem.load(.stringValue)
        #expect(captureClaim == "Apple Log 2")
        let sourceData = try Data(contentsOf: source)
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)

        do {
            _ = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000)
            Issue.record("An untagged source unexpectedly passed the Apple Log 2 input contract")
        } catch {
            #expect(error.localizedDescription.contains("input-color-contract"))
            #expect(error.localizedDescription.contains("Apple Log 2"))
        }
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mov"])
    }

    @available(macOS 27.0, *)
    @Test func taggedAppleLog2SourceRendersWithStreamProvenance() async throws {
        try await assertTaggedAppleLog2SourceRenders(codec: .hevc)
        try await assertTaggedAppleLog2SourceRenders(codec: .proRes422LT)
    }

    @available(macOS 27.0, *)
    private func assertTaggedAppleLog2SourceRenders(codec: AVVideoCodecType) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("apple-log2.mov")
        try await makeAppleLog2Fixture(at: source, codec: codec)
        let sourceAsset = AVURLAsset(url: source)
        let sourceTracks = try await sourceAsset.load(.tracks)
        let sourceVideoTrack = try #require(sourceTracks.first(where: { $0.mediaType == .video }))
        let sourceDescriptions = try await sourceVideoTrack.load(.formatDescriptions)
        let sourceFormat = try #require(sourceDescriptions.first)
        let sourceExtensions = CMFormatDescriptionGetExtensions(sourceFormat) as NSDictionary?
        func sourceExtensionValue(_ key: CFString) -> String? {
            sourceExtensions?[key].map { String(describing: $0) }
        }
        let sourceBitDepth = try #require(sourceExtensionValue(kCMFormatDescriptionExtension_BitsPerComponent))
        let sourceFullRange = sourceExtensionValue(kCMFormatDescriptionExtension_FullRangeVideo)
        let sourcePrimaries = sourceExtensionValue(kCMFormatDescriptionExtension_ColorPrimaries)
        let sourceTransfer = sourceExtensionValue(kCMFormatDescriptionExtension_TransferFunction)
        if codec == .hevc {
            #expect(sourceBitDepth == "10")
            #expect(sourceFullRange == "0")
        }

        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory)
        let renderResult = try await renderer.render(sourceURL: source, config: loadConfig(), bitrate: 2_000_000,
                                                     diagnosticsBundleDirectory: directory)
        let output = try #require(renderResult.outputURL)
        defer { try? FileManager.default.removeItem(at: output) }

        let decodedEvidence = try #require(renderResult.manifest.firstDecodedBuffer)
        #expect(decodedEvidence.pixelFormat == "RGhA")
        #expect(decodedEvidence.colorAttachments["logTransferFunction"] == "com.apple.apple-wide-gamut.apple-log")
        #expect(decodedEvidence.colorAttachments["yCbCrMatrix"] == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String))
        let neutral = try #require(decodedEvidence.samplePoints.first)
        #expect(neutral.x == 0 && neutral.y == 0)
        let red = try #require(Float(neutral.red))
        let green = try #require(Float(neutral.green))
        let blue = try #require(Float(neutral.blue))
        #expect(abs(red - 0.45) < 0.005)
        #expect(abs(green - 0.45) < 0.005)
        #expect(abs(blue - 0.45) < 0.005)
        let colored = try #require(decodedEvidence.samplePoints.dropFirst().first)
        let coloredRed = try #require(Float(colored.red))
        let coloredGreen = try #require(Float(colored.green))
        let coloredBlue = try #require(Float(colored.blue))
        // Independent BT.2020 nonconstant-luminance decode of the fixture's
        // quantized 10-bit video-range Y=458, Cb=467, Cr=557 at x=128.
        let encodedY = Float(458 - 64) / 876
        let encodedCb = Float(467 - 512) / 896
        let encodedCr = Float(557 - 512) / 896
        #expect(abs(coloredRed - (encodedY + 1.4746 * encodedCr)) < 0.005)
        #expect(abs(coloredGreen - (encodedY - 0.164553 * encodedCb - 0.571353 * encodedCr)) < 0.005)
        #expect(abs(coloredBlue - (encodedY + 1.8814 * encodedCb)) < 0.005)

        let outputAsset = AVURLAsset(url: output)
        let outputTracks = try await outputAsset.load(.tracks)
        let outputVideoTrack = try #require(outputTracks.first(where: { $0.mediaType == .video }))
        let outputDescriptions = try await outputVideoTrack.load(.formatDescriptions)
        #expect(CMFormatDescriptionGetMediaSubType(try #require(outputDescriptions.first)).fourCharCodeString == "hvc1")
        var values: [String: String] = [:]
        for item in try await outputAsset.load(.metadata) {
            if let key = item.key as? String, let value = try await item.load(.stringValue) { values[key] = value }
        }
        #expect(values["com.filmemulation.source-color-validation"] == "accepted-stream-tags")
        #expect(values["com.filmemulation.source-color-test-bypass"] == "false")
        #expect(values["com.filmemulation.capture-color-space"] == "Apple Log 2")
        let sourceJSON = try #require(values["com.filmemulation.source-color-provenance"])
        let provenance = try JSONDecoder().decode(RenderInputColorProvenance.self, from: Data(sourceJSON.utf8))
        #expect(provenance.formatDescriptions.count == 1)
        #expect(provenance.formatDescriptions[0].logTransferFunction == "com.apple.apple-wide-gamut.apple-log")
        #expect(provenance.formatDescriptions[0].bitDepth == sourceBitDepth)
        #expect(provenance.formatDescriptions[0].codec == codec.rawValue)
        #expect(provenance.formatDescriptions[0].yCbCrMatrix == (AVVideoYCbCrMatrix_ITU_R_2020 as String))
        #expect(provenance.formatDescriptions[0].fullRangeVideo == sourceFullRange)
        #expect(provenance.formatDescriptions[0].colorPrimaries == sourcePrimaries)
        #expect(provenance.formatDescriptions[0].transferFunction == sourceTransfer)
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
            outputDirectory: directory,
            allowsSyntheticInputForTests: true
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
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
            outputDirectory: directory,
            allowsSyntheticInputForTests: true
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
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
        let renderer = try PipelineRenderer(resourceBundle: testBundle, outputDirectory: directory, allowsSyntheticInputForTests: true)
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
        hasAudio: Bool = true,
        claimedCaptureColorSpace: String? = nil
    ) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        if let claimedCaptureColorSpace {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.filmemulation.capture-color-space" as NSString
            item.value = claimedCaptureColorSpace as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
        }
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

    @available(macOS 27.0, *)
    private func makeAppleLog2Fixture(at url: URL, codec: AVVideoCodecType) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let captureColor = AVMutableMetadataItem()
        captureColor.keySpace = .quickTimeMetadata
        captureColor.key = "com.filmemulation.capture-color-space" as NSString
        captureColor.value = "Apple Log 2" as NSString
        captureColor.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [captureColor]
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 256, 64,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else { throw FixtureError.sampleBuffer(status) }
        CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey,
                              kCVImageBufferLogTransferFunction_AppleLog2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw FixtureError.sampleBuffer(kCVReturnError)
        }
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                throw FixtureError.sampleBuffer(kCVReturnError)
            }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<64 {
                let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<256 { row[x] = UInt16((64 + 0.45 * 876).rounded()) << 6 }
            }
            let chromaPatches: [(Double, Double)] = [(0.5, 0.5), (0.55, 0.45), (0.45, 0.55), (0.58, 0.53)]
            for y in 0..<32 {
                let row = chromaBase.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<128 {
                    // Keep the diagnostic's center point (pixel x=128,
                    // chroma x=64) inside a patch, away from chroma edges.
                    let patchIndex = x < 48 ? 0 : x < 80 ? 2 : x < 112 ? 1 : 3
                    let patch = chromaPatches[patchIndex]
                    row[x * 2] = UInt16((64 + patch.0 * 896).rounded()) << 6
                    row[x * 2 + 1] = UInt16((64 + patch.1 * 896).rounded()) << 6
                }
            }
        }
        var formatHint: CMVideoFormatDescription?
        let hintStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatHint
        )
        guard hintStatus == noErr, let formatHint else { throw FixtureError.sampleBuffer(hintStatus) }
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: 256,
            AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [
                AVVideoLogTransferFunctionKey: kCVImageBufferLogTransferFunction_AppleLog2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ]
        if codec == .hevc {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAverageBitRateKey: 2_000_000
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings,
                                       sourceFormatHint: formatHint)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.writerStart(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                throw FixtureError.writerStart(writer.error)
            }
        }
        input.markAsFinished()
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
