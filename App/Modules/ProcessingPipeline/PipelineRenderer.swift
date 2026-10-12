import AVFoundation
@preconcurrency import Metal
import CoreVideo

/// AD-6: Metal GPU pipeline — hybrid 2-pass post-record render.
/// Pass 1: LUT + halation + glow (single fused Metal compute shader).
/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
/// Input: .mov URL carrying the Apple Log 2 stream tags (native camera codec).
/// Output: .mov URL (HEVC H.265, 4K, ~60 Mbps).
final class PipelineRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderQueue = DispatchQueue(label: "pipeline.render")
    private let resourceBundle: Bundle
    private let renderFailureAfterFrames: UInt32?
    private let audioAppendRejectionAfterSamples: Int?
    private let outputDirectory: URL?
    private let allowsSyntheticInputForTests: Bool

    // Cached pipeline states
    private var pass1Pipeline: MTLComputePipelineState?
    private var pass2Pipeline: MTLComputePipelineState?
    private var spatialStage: SpatialEffectsStage?
    private var grainTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?

    // Current LUT texture (loaded per-render based on stock config)
    private var lutTexture: MTLTexture?

    init(
        resourceBundle: Bundle = .main,
        renderFailureAfterFrames: UInt32? = nil,
        audioAppendRejectionAfterSamples: Int? = nil,
        outputDirectory: URL? = nil,
        allowsSyntheticInputForTests: Bool = false
    ) throws {
        self.resourceBundle = resourceBundle
        self.renderFailureAfterFrames = renderFailureAfterFrames
        self.audioAppendRejectionAfterSamples = audioAppendRejectionAfterSamples
        self.outputDirectory = outputDirectory
        self.allowsSyntheticInputForTests = allowsSyntheticInputForTests
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.noCommandQueue
        }
        self.commandQueue = queue

        // Create texture cache for efficient CVPixelBuffer ↔ Metal texture bridging
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else {
            throw RenderError.textureCacheCreationFailed
        }
        self.textureCache = textureCache

        try loadMetalShaders()
        try loadGrainVolume()
    }

    // MARK: - Public API

    /// Render a source clip with the given film stock configuration.
    func render(
        sourceURL: URL,
        config: FilmStockConfig,
        trimRange: CMTimeRange? = nil,
        bitrate: Int = RenderEncodingContract.averageBitRate
    ) async throws -> URL {
        (try await renderInternally(sourceURL: sourceURL, config: config, trimRange: trimRange, bitrate: bitrate)).outputURL
    }

    private static func captureColorSpace(from asset: AVAsset) async throws -> String? {
        for item in try await asset.load(.metadata) {
            guard let key = item.key as? String,
                  key == "com.filmemulation.capture-color-space" else { continue }
            return try await item.load(.stringValue)
        }
        return nil
    }

    private func renderInternally(
        sourceURL: URL,
        config: FilmStockConfig,
        trimRange: CMTimeRange? = nil,
        bitrate: Int = RenderEncodingContract.averageBitRate,
        collectDecodedBufferEvidence: Bool = false
    ) async throws -> (outputURL: URL, counters: RenderDiagnosticsManifest.Counters,
                       sourceColorProvenance: RenderInputColorProvenance,
                       firstDecodedBuffer: RenderDiagnosticsManifest.DecodedBufferEvidence?) {
        try Task.checkCancellation()
        try config.validate()

        let asset = AVAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let captureColorSpace = try await Self.captureColorSpace(from: asset)
        let sourceColorProvenance: RenderInputColorProvenance
        if allowsSyntheticInputForTests {
            sourceColorProvenance = .syntheticTestBypass(formatDescriptions, captureColorSpace: captureColorSpace)
        } else {
            do {
                sourceColorProvenance = try RenderInputColorProvenance.inspect(
                    formatDescriptions, captureColorSpace: captureColorSpace
                )
            } catch let error as RenderInputColorContractError {
                throw RenderError.stageFailed(
                    "input-color-contract", "Expected \(error.expected); observed \(error.observed)."
                )
            }
        }

        // Validate stream tags before opening LUT resources or creating output.
        try loadLUT(named: config.lutName)

        // Audio passthrough: copy audio track unchanged
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        try Task.checkCancellation()

        let renderWidth = naturalSize.width
        let renderHeight = naturalSize.height

        // Use naturalSize everywhere — encoded dimensions, never swapped.
        // Rotation is preserved via writerInput.transform below.
        //
        // The track tags establish Apple Log 2 input. The decoded RGBA values and
        // any AVFoundation conversion behavior remain unverified by this contract.
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            AVVideoAllowWideColorKey: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: renderWidth,
            kCVPixelBufferHeightKey as String: renderHeight
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw RenderError.stageFailed("video-reader-setup", "The video reader cannot accept the source track.")
        }
        reader.add(readerOutput)
        reader.timeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)

        // Audio reader (passthrough) uses its OWN AVAssetReader instance.
        // AVAssetReader is not thread-safe: the video path reads on
        // `renderQueue` while audio is copied on a separate queue, so sharing
        // one reader across both threads risks dropped or corrupted samples.
        var audioReader: AVAssetReader?
        var audioWriterInput: AVAssetWriterInput?
        if let audioTrack = audioTrack {
            let ar = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            guard ar.canAdd(audioOutput) else {
                throw RenderError.stageFailed("audio-reader-setup", "The audio reader cannot accept the source track.")
            }
            ar.add(audioOutput)
            ar.timeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)
            audioReader = ar
        }

        // Writer setup
        let outputURL = tempOutputURL()
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        let cancellationHandle = RenderCancellationHandle(writer: writer, videoReader: reader, audioReader: audioReader)
        var renderSucceeded = false
        defer {
            if !renderSucceeded {
                Self.abandonWriter(outputURL: outputURL, cancellationHandle: cancellationHandle)
            }
        }

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: 48,
            AVVideoExpectedSourceFrameRateKey: nominalFrameRate,
            // Offline encoding can use B-frames to spend the fixed bitrate more
            // efficiently on stochastic detail such as film grain.
            AVVideoAllowFrameReorderingKey: true
        ]

        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: RenderEncodingContract.codec),
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: videoCompression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: RenderEncodingContract.colorPrimaries,
                AVVideoTransferFunctionKey: RenderEncodingContract.transferFunction,
                AVVideoYCbCrMatrixKey: RenderEncodingContract.yCbCrMatrix
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        // BGRA 8-bit adaptor; HEVC encoder converts BGRA → Y′CbCr internally.
        // Output tagged Rec.709 SDR (LUT pack is "Apple Log 2 → Rec.709"); exact transfer
        // gamma (2.2 vs 2.4) still unverified — BT.709 transfer is the standard SDR tag.
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: renderWidth,
            kCVPixelBufferHeightKey as String: renderHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw RenderError.stageFailed("video-writer-setup", "The movie writer cannot accept the video input.")
        }
        writer.add(writerInput)
        writer.metadata = try RenderMovieMetadata.make(
            config: config, bitrate: bitrate, sourceColorProvenance: sourceColorProvenance
        )

        // Audio passthrough writer input
        // nil outputSettings + sourceFormatHint = pass compressed audio straight through
        if let audioTrack = audioTrack {
            let audioDesc = try await audioTrack.load(.formatDescriptions).first
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                                  sourceFormatHint: audioDesc)
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else {
                throw RenderError.stageFailed("audio-writer-setup", "The movie writer cannot accept the audio input.")
            }
            writer.add(audioInput)
            audioWriterInput = audioInput
        }

        do {
            guard writer.startWriting() else {
                throw RenderError.writerFailed(writer.error)
            }
            // Reader sample timestamps remain on the source timeline. Starting the
            // writer session at the trim origin maps the selected range to output 0.
            let sessionStart = (trimRange ?? CMTimeRange(start: .zero, duration: duration)).start
            writer.startSession(atSourceTime: sessionStart)

            guard reader.startReading() else {
                throw RenderError.readerFailed(reader.error)
            }
            if let audioReader, !audioReader.startReading() {
                throw RenderError.readerFailed(audioReader.error)
            }

            let frameResult = try await processFrames(
                videoReader: reader,
                readerOutput: readerOutput,
                adaptor: adaptor,
                writerInput: writerInput,
                writer: writer,
                config: config,
                audioReader: audioReader,
                audioWriterInput: audioWriterInput,
                cancellationHandle: cancellationHandle,
                captureFirstBufferEvidence: collectDecodedBufferEvidence
            )
            try Task.checkCancellation()
            guard frameResult.counters.processed > 0 else {
                throw RenderError.stageFailed("video-reader", "The selected source range contained no video frames.")
            }

            await withTaskCancellationHandler {
                await writer.finishWriting()
            } onCancel: {
                cancellationHandle.cancel()
            }
            try Task.checkCancellation()
            guard cancellationHandle.writerStatus == .completed else {
                throw RenderError.writerFailed(cancellationHandle.writerError)
            }
            guard cancellationHandle.videoReaderStatus == .completed else {
                throw RenderError.readerFailed(cancellationHandle.videoReaderError)
            }
            if audioReader != nil, cancellationHandle.audioReaderStatus != .completed {
                throw RenderError.readerFailed(cancellationHandle.audioReaderError)
            }
            renderSucceeded = true
            return (outputURL, frameResult.counters, sourceColorProvenance, frameResult.firstBufferEvidence)
        } catch {
            throw error
        }
    }

    /// Tear down a failed render and delete its partial output.
    ///
    /// An abandoned AVAssetWriter leaves a truncated file behind — no moov atom,
    /// so nothing can play it. That is worse than no file at all: it sits in the
    /// documents directory looking like a render, and a size-only check reports it
    /// as a finished job. Failures must leave no successful-looking partial output.
    private static func abandonWriter(outputURL: URL, cancellationHandle: RenderCancellationHandle) {
        cancellationHandle.cancel()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Runs the unchanged renderer while collecting a self-contained diagnostic bundle.
    /// Diagnostics are opt-in so the app's existing call site and output contract remain unchanged.
    func render(
        sourceURL: URL,
        config: FilmStockConfig,
        trimRange: CMTimeRange? = nil,
        bitrate: Int = RenderEncodingContract.averageBitRate,
        diagnosticsBundleDirectory: URL
    ) async throws -> RenderDiagnosticResult {
        let runID = UUID()
        let bundleURL = diagnosticsBundleDirectory.appendingPathComponent("render-\(runID.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } catch {
            throw RenderDiagnosticError.invalidBundleDirectory(diagnosticsBundleDirectory)
        }

        var manifest = RenderDiagnosticsManifest(
            runID: runID,
            startedAt: Date(),
            finishedAt: nil,
            stockID: config.stockId,
            iso: config.defaultISO,
            environment: RenderDiagnostics.makeEnvironment(device: device),
            input: await RenderDiagnostics.inspectMedia(url: sourceURL),
            output: nil,
            resources: diagnosticResources(for: config)
        )
        manifest.recipe = .init(config: config, averageBitRate: bitrate, codec: RenderEncodingContract.codec)
        let renderStart = Date()
        var resultOutput: URL?

        do {
            let renderResult = try await renderInternally(sourceURL: sourceURL, config: config, trimRange: trimRange,
                                                          bitrate: bitrate, collectDecodedBufferEvidence: true)
            let outputURL = renderResult.outputURL
            resultOutput = outputURL
            manifest.counters = renderResult.counters
            manifest.firstDecodedBuffer = renderResult.firstDecodedBuffer
            manifest.recipe = .init(config: config, averageBitRate: bitrate,
                                     codec: RenderEncodingContract.codec,
                                     sourceColorProvenance: renderResult.sourceColorProvenance)
            manifest.timings["render"] = Date().timeIntervalSince(renderStart)

            let bundledOutput = bundleURL.appendingPathComponent("rendered.mov")
            try FileManager.default.copyItem(at: outputURL, to: bundledOutput)
            manifest.output = await RenderDiagnostics.inspectMedia(url: bundledOutput)

            let sourceDirectory = bundleURL.appendingPathComponent("source-frames", isDirectory: true)
            let outputDirectory = bundleURL.appendingPathComponent("output-frames", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let sourceExtractionStart = Date()
            manifest.sourceFrames = await RenderDiagnostics.extractFrames(from: sourceURL, directory: sourceDirectory)
            manifest.timings["source-frame-extraction"] = Date().timeIntervalSince(sourceExtractionStart)
            let outputExtractionStart = Date()
            manifest.outputFrames = await RenderDiagnostics.extractFrames(from: bundledOutput, directory: outputDirectory)
            manifest.timings["output-frame-extraction"] = Date().timeIntervalSince(outputExtractionStart)
            manifest.succeeded = true
            manifest.finishedAt = Date()
            try RenderDiagnostics.writeManifest(manifest, to: bundleURL)
            return RenderDiagnosticResult(outputURL: outputURL, bundleURL: bundleURL, manifest: manifest)
        } catch {
            manifest.timings["render"] = Date().timeIntervalSince(renderStart)
            manifest.finishedAt = Date()
            manifest.error = error.localizedDescription
            manifest.failureStage = error is RenderContractError ? "configuration" : ((error as? RenderError)?.stage ?? "render")
            manifest.counters.failed = 1
            try? RenderDiagnostics.writeManifest(manifest, to: bundleURL)
            if let resultOutput {
                try? FileManager.default.removeItem(at: resultOutput)
            }
            throw error
        }
    }

    // MARK: - LUT Loading

    /// Parse a .cube LUT file and load it as a 3D Metal texture.
    private func loadLUT(named filename: String) throws {
        guard let path = findBundleFile(named: filename) ??
                resourceBundle.path(forResource: filename.replacingOccurrences(of: ".cube", with: ""),
                                 ofType: "cube", inDirectory: "LUTs") else {
            throw RenderError.missingResource("LUT file not found: \(filename)")
        }
        try loadLUTFromPath(path)
    }

    private func loadLUTFromURL(_ url: URL) throws {
        let data = try String(contentsOf: url, encoding: .utf8)
        let (size, values) = try parseCubeLUT(data)
        try createLUTTexture(size: size, values: values)
    }

    private func loadLUTFromPath(_ path: String) throws {
        let data = try String(contentsOfFile: path, encoding: .utf8)
        let (size, values) = try parseCubeLUT(data)
        try createLUTTexture(size: size, values: values)
    }

    /// Parse .cube format. Returns (size, rgbaValues).
    private func parseCubeLUT(_ content: String) throws -> (Int, [Float]) {
        var size = 0
        var values: [Float] = []
        var headerParsed = false

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                guard parts.count >= 2, let parsedSize = Int(parts[1]) else {
                    throw RenderError.invalidLUTData
                }
                size = parsedSize
                headerParsed = true
                continue
            }

            if headerParsed, trimmed.uppercased() == "DOMAIN_MIN" || trimmed.uppercased() == "DOMAIN_MAX" {
                continue
            }

            if headerParsed {
                // Parse RGB triplet
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let numericParts = parts.compactMap { Float($0) }
                if numericParts.count == 3 {
                    values.append(contentsOf: numericParts + [1.0]) // Add alpha = 1.0
                }
            }
        }

        guard size > 0, values.count == size * size * size * 4 else {
            throw RenderError.invalidLUTData
        }

        return (size, values)
    }

    /// Upload Resolve .cube RGB triplets to a 3D Metal texture (RGBA).
    private func createLUTTexture(size: Int, values: [Float]) throws {
        lutTexture = nil

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.mipmapLevelCount = 1
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.textureCreationFailed
        }

        // Resolve writes 3D cubes as RGB triplets with red varying fastest.
        // Metal's x/y/z texture axes map directly to r/g/b, respectively.
        values.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                bytesPerImage: size * size * 4 * MemoryLayout<Float>.size
            )
        }

        lutTexture = texture
    }

    // MARK: - Frame Processing

    private func processFrames(
        videoReader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writerInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        config: FilmStockConfig,
        audioReader: AVAssetReader?,
        audioWriterInput: AVAssetWriterInput?,
        cancellationHandle: RenderCancellationHandle,
        captureFirstBufferEvidence: Bool
    ) async throws -> (counters: RenderDiagnosticsManifest.Counters,
                       firstBufferEvidence: RenderDiagnosticsManifest.DecodedBufferEvidence?) {
        guard let lut = lutTexture else {
            throw RenderError.missingResource("LUT texture not loaded")
        }

        let counterBox = FrameCounterBox()
        let audioResult = AudioCopyResultBox()

        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(RenderDiagnosticsManifest.Counters, RenderDiagnosticsManifest.DecodedBufferEvidence?), Error>) in
            renderQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RenderError.stageFailed("renderer", "Renderer was released before frame processing."))
                    return
                }
                // These mutable values are owned exclusively by renderQueue.
                var frameIndex: UInt32 = 0
                var firstFrame = true
                var actualWidth = 0
                var actualHeight = 0
                var firstBufferEvidence: RenderDiagnosticsManifest.DecodedBufferEvidence?

                // Start audio passthrough on a parallel queue. The audio
                // reader is dedicated to audio, so it is only touched from
                // this queue (the video reader lives on `renderQueue`).
                let audioDone: DispatchWorkItem? = {
                    guard audioReader != nil, audioWriterInput != nil else { return nil }
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else {
                            audioResult.set(.failure(RenderError.stageFailed("audio-copy", "Renderer was released during audio copy.")))
                            return
                        }
                        let result = self.copyAudioSamples(
                            from: audioReader,
                            to: audioWriterInput,
                            cancellationHandle: cancellationHandle
                        )
                        audioResult.set(result)
                        if case .failure = result { cancellationHandle.cancel() }
                    }
                    DispatchQueue.global(qos: .utility).async(execute: work)
                    return work
                }()

                var videoFailure: Error?
                var reachedVideoEOF = false
                while !reachedVideoEOF {
                    if let audioFailure = audioResult.getFailure {
                        videoFailure = audioFailure
                        break
                    }
                    if cancellationHandle.writerStatus == .cancelled {
                        videoFailure = CancellationError()
                        break
                    }

                    // Read first so writer backpressure cannot hide reader EOF.
                    guard let sampleBuffer = cancellationHandle.copyNextVideoSample(from: readerOutput) else {
                        switch cancellationHandle.videoReaderStatus {
                        case .completed:
                            cancellationHandle.markVideoFinished(writerInput)
                            reachedVideoEOF = true
                        case .failed:
                            videoFailure = RenderError.readerFailed(cancellationHandle.videoReaderError)
                        case .cancelled:
                            videoFailure = CancellationError()
                        default:
                            videoFailure = RenderError.stageFailed("video-reader", "Video ended before the reader completed.")
                        }
                        break
                    }
                    counterBox.counters.decoded += 1

                    // A sample is already pending; wait for writer readiness.
                    var pollCount = 0
                    while !writerInput.isReadyForMoreMediaData {
                        if let audioFailure = audioResult.getFailure {
                            videoFailure = audioFailure
                            break
                        }
                        let writerStatus = cancellationHandle.writerStatus
                        if writerStatus == .failed || writerStatus == .cancelled {
                            videoFailure = writerStatus == .cancelled
                                ? CancellationError()
                                : RenderError.writerFailed(cancellationHandle.writerError)
                            break
                        }
                        usleep(1000)
                        pollCount += 1
                        if pollCount > 5000 {  // 5s timeout
                            // The writer has not failed, it simply never asked for
                            // more video — report that honestly instead of claiming
                            // an asset-writer failure.
                            videoFailure = RenderError.stageFailed(
                                "video-backpressure",
                                "The video writer did not accept frames for 5 seconds (audio input: \(audioWriterInput != nil))."
                            )
                            break
                        }
                    }
                    if videoFailure != nil { break }

                    guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        videoFailure = RenderError.stageFailed("decode", "Sample buffer has no pixel buffer.")
                        break
                    }
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    if firstFrame {
                        actualWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
                        actualHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
                        if captureFirstBufferEvidence {
                            firstBufferEvidence = Self.snapshotDecodedBuffer(sourcePixelBuffer)
                        }
                        firstFrame = false
                    }

                    // Process: input → pass1 (LUT) → spatial halation/glow → pass2 (grain) → output
                    switch self.renderFrame(
                        sourcePixelBuffer: sourcePixelBuffer,
                        context: FrameRenderContext(
                            adaptor: adaptor,
                            config: config,
                            lut: lut,
                            cancellationHandle: cancellationHandle
                        ),
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        size: MTLSize(width: actualWidth, height: actualHeight, depth: 1)
                    ) {
                    case .failure(let error):
                        videoFailure = audioResult.getFailure ?? error
                        break
                    case .success:
                        break
                    }
                    if videoFailure != nil { break }
                    counterBox.counters.processed += 1
                    counterBox.counters.appended += 1
                    frameIndex += 1
                }

                if videoFailure != nil {
                    // Cancel writer/reader to release an audio worker blocked on
                    // writer backpressure, then join it before returning.
                    cancellationHandle.cancel()
                }
                audioDone?.wait()

                if let videoFailure {
                    continuation.resume(throwing: videoFailure)
                } else if let audioFailure = audioResult.getFailure {
                    continuation.resume(throwing: audioFailure)
                } else if cancellationHandle.videoReaderStatus == .failed {
                    continuation.resume(throwing: RenderError.readerFailed(cancellationHandle.videoReaderError))
                } else if cancellationHandle.videoReaderStatus != .completed {
                    continuation.resume(throwing: CancellationError())
                } else if cancellationHandle.audioReaderStatus == .failed {
                    continuation.resume(throwing: RenderError.readerFailed(cancellationHandle.audioReaderError))
                } else {
                    continuation.resume(returning: (counterBox.counters, firstBufferEvidence))
                }
            }
          }
        } onCancel: {
            cancellationHandle.cancel()
        }
    }

    private static func snapshotDecodedBuffer(
        _ pixelBuffer: CVPixelBuffer
    ) -> RenderDiagnosticsManifest.DecodedBufferEvidence? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        var attachmentKeys: [(String, CFString)] = [
            ("colorPrimaries", kCVImageBufferColorPrimariesKey),
            ("transferFunction", kCVImageBufferTransferFunctionKey),
            ("yCbCrMatrix", kCVImageBufferYCbCrMatrixKey)
        ]
        if #available(iOS 17.2, macOS 14.2, tvOS 17.2, *) {
            attachmentKeys.append(("logTransferFunction", kCVImageBufferLogTransferFunctionKey))
        }
        let rawAttachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as NSDictionary?
        var attachments: [String: String] = [:]
        for (name, key) in attachmentKeys {
            if let value = rawAttachments?[key] { attachments[name] = String(describing: value) }
        }

        let pixelFormat = OSType(CVPixelBufferGetPixelFormatType(pixelBuffer)).fourCharCodeString
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf else {
            return .init(pixelFormat: pixelFormat, width: width, height: height,
                         colorAttachments: attachments, samplePoints: [])
        }
        let candidatePoints = [(0, 0), (width / 2, height / 2), (width - 1, height - 1)]
        var seenPoints = Set<String>()
        let points = candidatePoints.filter { seenPoints.insert("\($0.0),\($0.1)").inserted }
        let halfWordsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt16>.size
        let components = baseAddress.assumingMemoryBound(to: UInt16.self)
        let samples = points.map { x, y in
            let index = y * halfWordsPerRow + x * 4
            func value(_ offset: Int) -> String {
                let component = Float(Float16(bitPattern: components[index + offset]))
                return String(format: "%.6g", Double(component))
            }
            return RenderDiagnosticsManifest.DecodedBufferEvidence.RGBPoint(
                x: x, y: y, red: value(0), green: value(1), blue: value(2)
            )
        }
        return .init(pixelFormat: pixelFormat,
                     width: width, height: height, colorAttachments: attachments, samplePoints: samples)
    }

    /// Grade and encode a single frame: LUT pass, spatial halation/glow,
    /// grain pass, then append. Returns the stage failure to report, if any.
    private func renderFrame(
        sourcePixelBuffer: CVPixelBuffer,
        context: FrameRenderContext,
        frameIndex: UInt32,
        timestamp: CMTime,
        size: MTLSize
    ) -> Result<Void, Error> {
        if let renderFailureAfterFrames, frameIndex >= renderFailureAfterFrames {
            return .failure(RenderError.stageFailed("injected-frame-failure", "Synthetic writer failure after \(frameIndex) frames."))
        }
        let adaptor = context.adaptor
        let config = context.config
        let width = size.width
        let height = size.height

        // Get an output pixel buffer from the adaptor's pool
        guard let pool = adaptor.pixelBufferPool else {
            return .failure(RenderError.stageFailed("pixel-buffer-pool", "Writer pixel buffer pool is unavailable."))
        }
        var outputPixelBuffer: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard allocationStatus == kCVReturnSuccess, let outBuf = outputPixelBuffer else {
            return .failure(RenderError.stageFailed("pixel-buffer-allocation", "Unable to allocate output pixel buffer (\(allocationStatus))."))
        }

        guard let graded = runPass1(
            sourcePixelBuffer: sourcePixelBuffer,
            lut: context.lut,
            halationStrength: config.halationStrength,
            glowStrength: config.glowStrength,
            outputContrast: config.outputContrast,
            width: width,
            height: height
        ) else {
            return .failure(RenderError.stageFailed("gpu-pass-1", "The LUT GPU pass did not complete."))
        }

        guard let spatialStage,
              let diffused = spatialStage.apply(
                graded: graded,
                commandQueue: commandQueue,
                halationStrength: config.halationStrength,
                glowStrength: config.glowStrength,
                halationRadiusFraction: config.halationRadiusFraction,
                halationTint: config.halationTint,
                width: width,
                height: height
              ) else {
            return .failure(RenderError.stageFailed("gpu-spatial", "The spatial halation/glow stage did not complete."))
        }

        let grained = runPass2(
            inputTexture: diffused,
            outputPixelBuffer: outBuf,
            frameIndex: frameIndex,
            iso: config.defaultISO,
            grainSize: config.grainSize,
            edgeBoostMultiplier: config.effectiveRecipe.edgeBoostMultiplier,
            width: width,
            height: height
        )
        guard grained else {
            return .failure(RenderError.stageFailed("gpu-pass-2", "The grain GPU pass did not complete."))
        }

        guard context.cancellationHandle.appendVideo(outBuf, withPresentationTime: timestamp, using: adaptor) else {
            return .failure(RenderError.stageFailed("writer-append", context.cancellationHandle.writerError?.localizedDescription ?? "Writer rejected a processed frame."))
        }
        return .success(())
    }

    /// Copies audio samples from the dedicated audio reader to the writer
    /// input, waiting out backpressure instead of dropping samples. The
    /// previous loop called `append` while the input was not ready, which
    /// returned false and silently discarded samples (gaps/silent audio).
    /// Runs synchronously on the calling queue — dispatch on a background queue.
    private func copyAudioSamples(
        from audioReader: AVAssetReader?,
        to audioWriterInput: AVAssetWriterInput?,
        cancellationHandle: RenderCancellationHandle
    ) -> Result<Void, Error> {
        guard let audioReader, let audioWriter = audioWriterInput else { return .success(()) }
        guard let audioOutput = audioReader.outputs.first as? AVAssetReaderTrackOutput else {
            return .failure(RenderError.stageFailed("audio-reader", "The audio reader has no track output."))
        }

        // Mark the audio input finished as soon as the audio is exhausted.
        //
        // This must happen HERE, not in the video loop. Audio is a cheap
        // passthrough while video frames go through three GPU passes, so the
        // audio thread races far ahead of the video and reaches end-of-track
        // long before the video does. AVAssetWriter will not hand out more
        // video buffers while it is still waiting on another input, so leaving
        // the audio input open deadlocked the writer: the video input never
        // became ready, the frame loop timed out, and the render failed (or, on
        // device, appeared to hang).
        var appendedSamples = 0
        while true {
            guard let sample = cancellationHandle.copyNextAudioSample(from: audioOutput) else {
                switch cancellationHandle.audioReaderStatus {
                case .completed:
                    cancellationHandle.markAudioFinished(audioWriter)
                    return .success(())
                case .failed: return .failure(RenderError.readerFailed(cancellationHandle.audioReaderError))
                case .cancelled: return .failure(CancellationError())
                default: return .failure(RenderError.stageFailed("audio-reader", "Audio ended before the reader completed."))
                }
            }

            if let audioAppendRejectionAfterSamples, appendedSamples >= audioAppendRejectionAfterSamples {
                return .failure(RenderError.stageFailed("audio-append", "Synthetic audio append rejection."))
            }
            var pollCount = 0
            while !audioWriter.isReadyForMoreMediaData {
                let writerStatus = cancellationHandle.writerStatus
                if writerStatus == .failed || writerStatus == .cancelled {
                    if writerStatus == .cancelled { return .failure(CancellationError()) }
                    return .failure(RenderError.stageFailed("audio-writer", cancellationHandle.writerError?.localizedDescription ?? "Writer failed while copying audio."))
                }
                usleep(1000)
                pollCount += 1
                if pollCount > 30_000 {  // 30s safety timeout
                    return .failure(RenderError.stageFailed("audio-backpressure", "The audio writer did not accept samples for 30 seconds."))
                }
            }
            if !cancellationHandle.appendAudio(sample, using: audioWriter) {
                return .failure(RenderError.stageFailed("audio-append", cancellationHandle.writerError?.localizedDescription ?? "The audio writer rejected a sample."))
            }
            appendedSamples += 1
        }
    }

    // MARK: - GPU Passes

    /// Pass 1: LUT + halation + glow. Returns the intermediate Metal texture.
    private func runPass1(
        sourcePixelBuffer: CVPixelBuffer,
        lut: MTLTexture,
        halationStrength: Float,
        glowStrength: Float,
        outputContrast: Float,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        // Create source texture from CVPixelBuffer via texture cache
        guard let source = makeTexture(from: sourcePixelBuffer, format: .rgba16Float),
              let intermediateTexture = makeIntermediateTexture(width: width, height: height) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var halation = halationStrength
        var glow = glowStrength
        var contrast = outputContrast

        encoder.setComputePipelineState(pass1Pipeline!)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(intermediateTexture, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&halation, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&glow, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&contrast, length: MemoryLayout<Float>.size, index: 2)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(source.cvTexture) {}

        return commandBuffer.status == .completed ? intermediateTexture : nil
    }

    /// Pass 2: grain. Writes result directly into the output pixel buffer.
    /// Returns true on success.
    private func runPass2(
        inputTexture: MTLTexture,
        outputPixelBuffer: CVPixelBuffer,
        frameIndex: UInt32,
        iso: Float,
        grainSize: Float,
        edgeBoostMultiplier: Float,
        width: Int,
        height: Int
    ) -> Bool {
        guard let output = makeTexture(from: outputPixelBuffer, format: .bgra8Unorm) else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        var uniforms = GrainUniforms(
            frameIndex: frameIndex, iso: iso, grainSize: grainSize,
            edgeBoostMultiplier: edgeBoostMultiplier
        )

        encoder.setComputePipelineState(pass2Pipeline!)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(output.texture, index: 1)
        encoder.setTexture(grainTexture!, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(output.cvTexture) {}

        return commandBuffer.status == .completed
    }


    // MARK: - Texture Helpers

    /// Create a Metal texture from a CVPixelBuffer using the texture cache.
    private struct PixelBufferTexture {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> PixelBufferTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return PixelBufferTexture(cvTexture: cvTexture, texture: texture)
    }

    /// Create an intermediate RGBA16Float texture for pass output.
    private func makeIntermediateTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)
    }


    // MARK: - Shader & Grain Loading

    private func loadMetalShaders() throws {
        // Resolve from the app or test bundle that owns the renderer resources.
        if let library = try? device.makeDefaultLibrary(bundle: resourceBundle) {
            try makePipelines(from: library)
            return
        }
        // Fallback: look for default.metallib next to the executable (macOS CLI).
        let exePath = resourceBundle.executablePath ?? CommandLine.arguments[0]
        let exeDir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
        let metallibURL = exeDir.appendingPathComponent("default.metallib")
        if FileManager.default.fileExists(atPath: metallibURL.path) {
            let library = try device.makeLibrary(URL: metallibURL)
            try makePipelines(from: library)
            return
        }
        throw RenderError.missingShader("default.metallib not found in bundle or next to executable")
    }

    /// Resolve every compute kernel the pipeline needs from one library.
    private func makePipelines(from library: MTLLibrary) throws {
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        pass1Pipeline = try pipeline("pass1_lut_halation_glow")
        pass2Pipeline = try pipeline("pass2_grain")
        spatialStage = try SpatialEffectsStage(device: device, library: library)
    }

    private func loadGrainVolume() throws {
        // Folder references can land differently depending on Xcode version.
        // Enumerate the bundle to find grain3d.raw wherever it landed.
        let grainPath = findBundleFile(named: "grain3d.raw")
            ?? resourceBundle.path(forResource: "grain3d", ofType: "raw", inDirectory: "Grain")
            ?? resourceBundle.path(forResource: "grain3d", ofType: "raw")
        guard let grainPath else {
            throw RenderError.missingResource("Grain/grain3d.raw not found in bundle")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: grainPath))

        let size = 128
        let expectedBytes = size * size * size * MemoryLayout<Float>.size
        guard data.count >= expectedBytes else {
            throw RenderError.invalidGrainData
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .r32Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.mipmapLevelCount = 1
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.textureCreationFailed
        }

        data.withUnsafeBytes { ptr in
            let region = MTLRegionMake3D(0, 0, 0, size, size, size)
            texture.replace(
                region: region,
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: size * MemoryLayout<Float>.size,
                bytesPerImage: size * size * MemoryLayout<Float>.size
            )
        }
        grainTexture = texture
    }

    // MARK: - Helpers

    /// Recursively search the bundle for a file by name. Handles folder references.
    private func findBundleFile(named filename: String) -> String? {
        guard let resourcePath = resourceBundle.resourcePath else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: resourcePath),
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == filename {
                return url.path
            }
        }
        return nil
    }

    private func diagnosticResources(for config: FilmStockConfig) -> [RenderDiagnosticsManifest.Resource] {
        var resources: [RenderDiagnosticsManifest.Resource] = []
        if let lut = findBundleFile(named: config.lutName) {
            resources.append(RenderDiagnostics.resource(kind: "lut", url: URL(fileURLWithPath: lut)))
        }
        if let grain = findBundleFile(named: "grain3d.raw") {
            resources.append(RenderDiagnostics.resource(kind: "grain", url: URL(fileURLWithPath: grain)))
        }
        if let executablePath = resourceBundle.executablePath {
            let metallib = URL(fileURLWithPath: executablePath).deletingLastPathComponent().appendingPathComponent("default.metallib")
            if FileManager.default.fileExists(atPath: metallib.path) {
                resources.append(RenderDiagnostics.resource(kind: "metallib", url: metallib))
            }
        }
        return resources
    }

    /// Unique output URL. The timestamp alone is only second-resolution, so two
    /// renders started within the same second collided: AVAssetWriter will not
    /// overwrite an existing file and failed with "Cannot Save", which the queue
    /// then masked by saving the *source* clip to Photos. Add a short random
    /// suffix and skip any name that already exists on disk.
    private func tempOutputURL() -> URL {
        // Use documents directory so output persists for viewing/sharing.
        let docs = outputDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return Self.uniqueOutputURL(in: docs)
    }

    /// Pick a render output name that no other render can collide with.
    ///
    /// Extracted so it can be tested without a Metal device: the collision it
    /// prevents previously surfaced as a failed render whose fallback saved the
    /// unprocessed source clip, which looked like "the grade and grain were not
    /// applied" rather than like an error.
    static func uniqueOutputURL(in directory: URL, now: Date = Date()) -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        for _ in 0..<16 {
            let suffix = String(UInt32.random(in: 0..<0x10000), radix: 16)
            let candidate = directory.appendingPathComponent("render_\(stamp)_\(suffix).mov")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Astronomically unlikely; keep the render working rather than fail.
        return directory.appendingPathComponent("render_\(UUID().uuidString).mov")
    }
}

// MARK: - Supporting Types

struct GrainUniforms {
    var frameIndex: UInt32
    var iso: Float
    var grainSize: Float
    var edgeBoostMultiplier: Float = 0
}

/// Everything one frame needs to be graded and appended, bundled so the frame
/// loop's per-frame helper keeps a manageable parameter list.
private struct FrameRenderContext {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let config: FilmStockConfig
    let lut: MTLTexture
    let cancellationHandle: RenderCancellationHandle
}

/// Frame processing is serialized on `renderQueue`; this box avoids crossing a mutable
/// value capture into that closure while retaining exact per-run diagnostic counters.
private final class FrameCounterBox: @unchecked Sendable {
    var counters = RenderDiagnosticsManifest.Counters()
}

/// Captures the result from the dedicated audio-copy worker for the render queue.
private final class AudioCopyResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    var getFailure: Error? {
        lock.lock()
        defer { lock.unlock() }
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

/// Serializes reader cancellation with sample copies and writer cancellation
/// with appends. Each worker releases its lane lock before waiting for
/// backpressure, so cancellation can acquire the lock and unblock it.
private final class RenderCancellationHandle: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoReader: AVAssetReader
    private let audioReader: AVAssetReader?
    private let writerLock = NSLock()
    private let videoReaderLock = NSLock()
    private let audioReaderLock = NSLock()

    init(writer: AVAssetWriter, videoReader: AVAssetReader, audioReader: AVAssetReader?) {
        self.writer = writer
        self.videoReader = videoReader
        self.audioReader = audioReader
    }

    func cancel() {
        // Workers never hold a reader lock while acquiring the writer lock.
        // Cancel the writer first to release backpressure, then stop each
        // reader only after any in-flight copy has returned.
        writerLock.lock()
        writer.cancelWriting()
        writerLock.unlock()

        videoReaderLock.lock()
        videoReader.cancelReading()
        videoReaderLock.unlock()

        if let audioReader {
            audioReaderLock.lock()
            audioReader.cancelReading()
            audioReaderLock.unlock()
        }
    }

    func copyNextVideoSample(from output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        videoReaderLock.lock()
        defer { videoReaderLock.unlock() }
        return output.copyNextSampleBuffer()
    }

    func copyNextAudioSample(from output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        audioReaderLock.lock()
        defer { audioReaderLock.unlock() }
        return output.copyNextSampleBuffer()
    }

    var videoReaderStatus: AVAssetReader.Status {
        videoReaderLock.lock()
        defer { videoReaderLock.unlock() }
        return videoReader.status
    }

    var videoReaderError: Error? {
        videoReaderLock.lock()
        defer { videoReaderLock.unlock() }
        return videoReader.error
    }

    var audioReaderStatus: AVAssetReader.Status {
        guard let audioReader else { return .unknown }
        audioReaderLock.lock()
        defer { audioReaderLock.unlock() }
        return audioReader.status
    }

    var audioReaderError: Error? {
        guard let audioReader else { return nil }
        audioReaderLock.lock()
        defer { audioReaderLock.unlock() }
        return audioReader.error
    }

    var writerStatus: AVAssetWriter.Status {
        writerLock.lock()
        defer { writerLock.unlock() }
        return writer.status
    }

    var writerError: Error? {
        writerLock.lock()
        defer { writerLock.unlock() }
        return writer.error
    }

    func appendVideo(
        _ buffer: CVPixelBuffer,
        withPresentationTime time: CMTime,
        using adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> Bool {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard writer.status != .cancelled else { return false }
        return adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sample: CMSampleBuffer, using input: AVAssetWriterInput) -> Bool {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard writer.status != .cancelled else { return false }
        return input.append(sample)
    }

    func markVideoFinished(_ input: AVAssetWriterInput) {
        writerLock.lock()
        defer { writerLock.unlock() }
        input.markAsFinished()
    }

    func markAudioFinished(_ input: AVAssetWriterInput) {
        writerLock.lock()
        defer { writerLock.unlock() }
        input.markAsFinished()
    }
}

enum RenderError: LocalizedError {
    case noMetalDevice
    case noCommandQueue
    case noVideoTrack
    case readerFailed(Error?)
    case writerFailed(Error?)
    case missingShader(String)
    case missingFunction(String)
    case missingResource(String)
    case invalidGrainData
    case invalidLUTData
    case textureCreationFailed
    case textureCacheCreationFailed
    case stageFailed(String, String)

    var stage: String? {
        if case .stageFailed(let stage, _) = self { return stage }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "Metal is not available on this device."
        case .noCommandQueue: return "Failed to create Metal command queue."
        case .noVideoTrack: return "Source video has no video track."
        case .readerFailed(let err): return "Asset reader failed: \(err?.localizedDescription ?? "unknown")"
        case .writerFailed(let err):
            guard let err else { return "Asset writer failed: nil error" }
            let nsError = err as NSError
            return "Asset writer failed: \(err.localizedDescription) [\(nsError.domain) \(nsError.code)] \(nsError.userInfo)"
        case .missingShader(let name): return "Missing shader: \(name)"
        case .missingFunction(let name): return "Missing Metal function: \(name)"
        case .missingResource(let name): return "Missing resource: \(name)"
        case .invalidGrainData: return "Grain volume data is invalid or truncated."
        case .invalidLUTData: return "Failed to parse .cube LUT file."
        case .textureCreationFailed: return "Failed to create Metal texture."
        case .textureCacheCreationFailed: return "Failed to create Metal texture cache."
        case .stageFailed(let stage, let message): return "\(stage): \(message)"
        }
    }
}
