import AVFoundation
import CoreMedia
@preconcurrency import Metal
import CoreVideo

/// The sample-buffer payload the iOS 26 / macOS 26 asset-reader provider vends.
/// `AVAssetReader.outputProvider(for:)` is the non-deprecated replacement for
/// `AVAssetReader.add(_:)` plus `copyNextSampleBuffer()`.
typealias ReadySampleProvider = AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>

/// AD-6: Metal GPU pipeline — hybrid 2-pass post-record render.
/// Pass 1: LUT + halation + glow (single fused Metal compute shader).
/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
/// Input: .mov URL carrying the Apple Log 2 stream tags (native camera codec).
/// Output: .mov URL (HEVC H.265, 4K, ~60 Mbps).
///
/// Sample transport uses the iOS 26 / macOS 26 receiver/provider API
/// (`AVAssetReader.outputProvider(for:)`, `AVAssetWriter.inputReceiver(for:)`,
/// `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`). The
/// receiver's async `append(_:)` performs the backpressure wait that the old
/// `isReadyForMoreMediaData` polling loop did, and the provider's `next()`
/// replaces `copyNextSampleBuffer()`. The GPU passes themselves — LUT,
/// halation/glow, grain — are untouched, so the rendered pixels and frame
/// timing are unchanged.
final class PipelineRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderQueue = DispatchQueue(label: "pipeline.render")
    private let resourceBundle: Bundle
    private let renderFailureAfterFrames: UInt32?
    private let audioAppendRejectionAfterSamples: Int?
    private let outputDirectory: URL?
    private let allowsSyntheticInputForTests: Bool
    /// Test-only: the transport ramp this renderer applies, instead of resolving
    /// the Settings switch and the command-line knobs at render time.
    /// Production leaves it nil and reads the switch, the way the app does.
    private let transportRampOverride: LightLeakTransport?
    /// Test-only: when set, the video lane performs this instead of the
    /// receiver's real `append`. A test uses it to hold an append open forever
    /// — the writer backpressure a cancelled writer never releases — and prove
    /// that the raced append still releases the frame loop. Production leaves
    /// it nil, so the real append runs unchanged.
    private let videoAppendOverride: (@Sendable (CVReadOnlyPixelBuffer, CMTime) async throws -> Void)?

    // Cached pipeline states
    private var pass1Pipeline: MTLComputePipelineState?
    private var pass2Pipeline: MTLComputePipelineState?
    private var hlgPipeline: MTLComputePipelineState?
    private var spatialStage: SpatialEffectsStage?
    private var grainTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?

    // Current LUT texture (loaded per-render based on stock config)
    private var lutTexture: MTLTexture?

    /// Name of the LUT currently in `lutTexture`, used only by the debug
    /// single-frame render to avoid re-parsing a .cube file on every slider drag.
    private var debugLUTName: String?

    init(
        resourceBundle: Bundle = .main,
        renderFailureAfterFrames: UInt32? = nil,
        audioAppendRejectionAfterSamples: Int? = nil,
        outputDirectory: URL? = nil,
        allowsSyntheticInputForTests: Bool = false,
        transportRamp: LightLeakTransport? = nil,
        videoAppendOverride: (@Sendable (CVReadOnlyPixelBuffer, CMTime) async throws -> Void)? = nil
    ) throws {
        self.resourceBundle = resourceBundle
        self.renderFailureAfterFrames = renderFailureAfterFrames
        self.audioAppendRejectionAfterSamples = audioAppendRejectionAfterSamples
        self.outputDirectory = outputDirectory
        self.allowsSyntheticInputForTests = allowsSyntheticInputForTests
        self.transportRampOverride = transportRamp
        self.videoAppendOverride = videoAppendOverride
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
    ///
    /// `capturePolicy` is the job's persisted enqueue-time policy. It selects the
    /// grain temporal cadence and the shutter metadata; `nil` is the legacy path
    /// (per-frame grain, `1/48`). It is never read from live UI.
    /// `progress`, when supplied, is called with a monotonic, clamped fraction
    /// (`0...<1`) as frames are appended, then with `1` once the writer has
    /// finished. The callback is `@Sendable` and is invoked from the render
    /// task, not the main actor; the caller owns any hop and throttling is
    /// already applied here.
    func render(
        sourceURL: URL,
        config: FilmStockConfig,
        trimRange: CMTimeRange? = nil,
        bitrate: Int = RenderEncodingContract.averageBitRate,
        capturePolicy: RenderCapturePolicy? = nil,
        isImportedSource: Bool = false,
        framing: DeliveryFraming = .widescreen,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        (try await renderInternally(sourceURL: sourceURL, config: config, trimRange: trimRange,
                                    bitrate: bitrate, capturePolicy: capturePolicy,
                                    isImportedSource: isImportedSource, framing: framing,
                                    progress: progress)).outputURL
    }

    /// The take's lamp record, read from the source movie's own tags. Nil for a
    /// source recorded before the control existed, which is not the same
    /// statement as "the lamp was off".
    private static func flashRecord(from asset: AVAsset) async throws -> FlashRecord? {
        var values: [String: String] = [:]
        for item in try await asset.load(.metadata) {
            guard let key = item.key as? String,
                  key.hasPrefix("com.filmemulation.flash-"),
                  let value = try await item.load(.stringValue) else { continue }
            values[String(key.dropFirst("com.filmemulation.".count))] = value
        }
        return FlashRecord.decode(values)
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
        capturePolicy: RenderCapturePolicy? = nil,
        isImportedSource: Bool = false,
        framing: DeliveryFraming = .widescreen,
        collectDecodedBufferEvidence: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (outputURL: URL, counters: RenderDiagnosticsManifest.Counters,
                       sourceColorProvenance: RenderInputColorProvenance,
                       firstDecodedBuffer: RenderDiagnosticsManifest.DecodedBufferEvidence?) {
        try Task.checkCancellation()
        try config.validate()

        let asset = AVURLAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let captureColorSpace = try await Self.captureColorSpace(from: asset)
        // The lamp is a fact about the take, not about the render: read it back
        // from the source so the delivered movie states the light that made it.
        let flash = try await Self.flashRecord(from: asset)
        let sourceColorProvenance: RenderInputColorProvenance
        if allowsSyntheticInputForTests {
            sourceColorProvenance = .syntheticTestBypass(formatDescriptions, captureColorSpace: captureColorSpace)
        } else {
            do {
                sourceColorProvenance = try RenderInputColorProvenance.inspect(
                    formatDescriptions, captureColorSpace: captureColorSpace,
                    expectedProfile: capturePolicy?.sourceProfile ?? .appleLog2
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

        // The source range this render actually reads. Frame presentation
        // times are on the source timeline, so progress maps them onto this
        // range.
        let renderRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)

        // Measure once so the highlight hold does not breathe with the framing.
        // Neutral exposure does not need the extra decode pass.
        let sourceProfile = capturePolicy?.sourceProfile ?? .appleLog2
        let peakCodeAdapter: (@Sendable (CVPixelBuffer) -> [Float])?
        if sourceProfile == .hlgBT2020 {
            peakCodeAdapter = { [self] buffer in
                self.renderQueue.sync {
                    guard let source = self.preparedSource(buffer, expectedProfile: .hlgBT2020) else { return [] }
                    return self.peakCodes(of: source.texture)
                }
            }
        } else {
            peakCodeAdapter = nil
        }
        let highlightCeiling: Float?
        if config.effectivePushPull.isNeutral {
            highlightCeiling = nil
        } else {
            highlightCeiling = await Self.measureHighlightCeiling(asset: asset, track: videoTrack, range: renderRange,
                sourceProfile: sourceProfile, peakCodeAdapter: peakCodeAdapter)
        }

        let sourceWidth = naturalSize.width
        let sourceHeight = naturalSize.height
        // Delivery framing is geometry, not colour: 4:3 writes the crop's own
        // size and fills it with the centre of the decoded frame. The source
        // reader stays at the encoded size, so the crop is a real crop and
        // never a squeeze of the whole frame into fewer columns.
        let delivery = framing.delivery(forSourceSize: naturalSize)
        guard delivery.deliveredWidth > 0, delivery.deliveredHeight > 0 else {
            throw RenderError.stageFailed("delivery-framing", "The source has no usable dimensions.")
        }
        // What Photos shows for the delivered clip: the encoded size with the
        // delivery transform applied, not the sensor shape.
        let deliveryOrientation = RenderDeliveryOrientation.from(naturalSize: delivery.deliveredSize,
                                                                 preferredTransform: preferredTransform)

        // Use naturalSize everywhere — encoded dimensions, never swapped.
        // Rotation is preserved via writerInput.transform below.
        //
        // The track tags establish Apple Log 2 input. The decoded RGBA values and
        // any AVFoundation conversion behavior remain unverified by this contract.
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: capturePolicy?.sourceProfile == .hlgBT2020
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_64RGBAHalf,
            AVVideoAllowWideColorKey: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: sourceWidth,
            kCVPixelBufferHeightKey as String: sourceHeight
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        guard reader.canAdd(readerOutput) else {
            throw RenderError.stageFailed("video-reader-setup", "The video reader cannot accept the source track.")
        }
        // `outputProvider(for:)` registers the output and vends its samples; it
        // replaces `add(_:)` + `copyNextSampleBuffer()`.
        let videoProvider = reader.outputProvider(for: readerOutput)
        reader.timeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)

        // Audio reader (passthrough) uses its OWN AVAssetReader instance.
        // AVAssetReader is not thread-safe: the video path reads on
        // `renderQueue` while audio is copied on a separate queue, so sharing
        // one reader across both threads risks dropped or corrupted samples.
        var audioReader: AVAssetReader?
        var audioProvider: ReadySampleProvider?
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if let audioTrack = audioTrack {
            let ar = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard ar.canAdd(audioOutput) else {
                throw RenderError.stageFailed("audio-reader-setup", "The audio reader cannot accept the source track.")
            }
            audioProvider = ar.outputProvider(for: audioOutput)
            ar.timeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)
            audioReader = ar
        }

        // Writer setup
        // The transport ramp: the film is already rolling when the take starts, so
        // the delivered timeline is the leader plus the take, and the take itself
        // is over-exposed at both ends while the transport finds its speed. It is
        // all counted in frames, so it needs the take's cadence.
        let lightLeak = transportRampOverride ?? LightLeakTransport.resolved()
        let frameRate = Double(nominalFrameRate)
        let frameDuration = CMTime(seconds: frameRate > 0 ? 1 / frameRate : 1 / 24,
                                   preferredTimescale: 600)
        let leaderDuration = CMTimeMultiply(frameDuration, multiplier: Int32(lightLeak.leaderCount))
        // The frame ahead of the film: the take at its metered exposure, so the
        // clip can be recognised. It is one more frame on the front, and the
        // session starts there, which leaves the take's own frames and its sound
        // exactly where the reader put them.
        let leadsWithNominalFrame = lightLeak.isActive && lightLeak.opensWithNominalFrame
        let posterDuration = leadsWithNominalFrame ? frameDuration : .zero
        let takeFrameCount = max(Int((renderRange.duration.seconds * frameRate).rounded()), 0)

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

        let writerOutputSettings = RenderVideoSettings.output(
            width: delivery.deliveredWidth, height: delivery.deliveredHeight,
            bitrate: bitrate, nominalFrameRate: nominalFrameRate
        )

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        writerInput.transform = preferredTransform

        // BGRA 8-bit receiver pool; HEVC encoder converts BGRA → Y′CbCr internally.
        // Output tagged Rec.709 SDR (LUT pack is "Apple Log 2 → Rec.709"); exact transfer
        // gamma (2.2 vs 2.4) still unverified — BT.709 transfer is the standard SDR tag.
        var sourcePixelBufferAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: delivery.deliveredWidth, height: delivery.deliveredHeight),
            compatibility: [.metalTexture]
        )
        sourcePixelBufferAttributes.backing = .ioSurface

        guard writer.canAdd(writerInput) else {
            throw RenderError.stageFailed("video-writer-setup", "The movie writer cannot accept the video input.")
        }
        // `inputPixelBufferReceiver(for:pixelBufferAttributes:)` registers the
        // input and vends the pool + append surface; it replaces `add(_:)` plus
        // `AVAssetWriterInputPixelBufferAdaptor`.
        let videoReceiver = writer.inputPixelBufferReceiver(
            for: writerInput, pixelBufferAttributes: sourcePixelBufferAttributes
        )
        writer.metadata = try RenderMovieMetadata.make(
            config: config, bitrate: bitrate, sourceColorProvenance: sourceColorProvenance,
            orientation: deliveryOrientation, capturePolicy: capturePolicy,
            isImportedSource: isImportedSource, sourceNominalFrameRate: Double(nominalFrameRate),
            flash: flash, framing: framing, deliveredSize: delivery.deliveredSize
        )

        // Audio passthrough writer input
        // nil outputSettings + sourceFormatHint = pass compressed audio straight through
        if let audioTrack = audioTrack {
            let audioDesc = try await audioTrack.load(.formatDescriptions).first
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                                  sourceFormatHint: audioDesc)
            guard writer.canAdd(audioInput) else {
                throw RenderError.stageFailed("audio-writer-setup", "The movie writer cannot accept the audio input.")
            }
            audioReceiver = writer.inputReceiver(for: audioInput)
        }

        do {
            do {
                try writer.start()
            } catch {
                throw RenderError.writerFailed(writer.error)
            }
            // Reader sample timestamps remain on the source timeline. Starting the
            // writer session at the trim origin maps the selected range to output 0
            // — and, with the transport ramp on, one leader earlier: the film that
            // ran before the take belongs in front of it rather than after it,
            // which is also what leaves the take's own sound where the reader put
            // it.
            let sessionStart = CMTimeSubtract(CMTimeSubtract(renderRange.start, leaderDuration), posterDuration)
            writer.startSession(atSourceTime: sessionStart)

            do {
                try reader.start()
            } catch {
                throw RenderError.readerFailed(reader.error)
            }
            if let audioReader {
                do {
                    try audioReader.start()
                } catch {
                    throw RenderError.readerFailed(audioReader.error)
                }
            }

            let frameResult = try await processFrames(
                videoProvider: videoProvider,
                videoReceiver: videoReceiver,
                config: config,
                delivery: delivery,
                highlightCeiling: highlightCeiling,
                audioProvider: audioProvider,
                audioReceiver: audioReceiver,
                cancellationHandle: cancellationHandle,
                grainPairing: capturePolicy?.grainPairing ?? .perFrame,
                captureFirstBufferEvidence: collectDecodedBufferEvidence,
                progress: progress,
                progressRange: renderRange,
                sourceProfile: capturePolicy?.sourceProfile ?? .appleLog2,
                lightLeak: lightLeak,
                frameDuration: frameDuration,
                takeFrameCount: takeFrameCount,
                leadsWithNominalFrame: leadsWithNominalFrame
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
            // The movie is fully written; only now report completion.
            progress?(RenderProgressAccumulator.finishFraction)
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
        framing: DeliveryFraming = .widescreen,
        diagnosticsBundleDirectory: URL,
        capturePolicy: RenderCapturePolicy? = nil
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
                                                          bitrate: bitrate, capturePolicy: capturePolicy, framing: framing,
                                                          collectDecodedBufferEvidence: true)
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

    // MARK: - Debug Single-Frame Render

    /// Tunable grain/halation/glow values for one debug single-frame render.
    ///
    /// The LUT and output contrast still come from the stock config; only the
    /// effect dials the debug sheet varies live here, so a drag can never
    /// disturb the shipping look or the video render path. Grain is owned by the
    /// print gauge alone — the gauge sets both footprint and presence — so there
    /// is no ISO-driven loudness term: the stock's exposure index is passed
    /// through unchanged and does not scale grain.
    struct DebugFrameParameters: Sendable, Equatable {
        private let stockConfig: FilmStockConfig
        var gauge: PrintGauge
        var stockGrainSize: Float
        /// Grain size and presence are dialled independently here, so the two
        /// axes can be compared on one frame. Picking a gauge re-seeds both.
        var sizeMultiplier: Float
        var presenceMultiplier: Float
        var edgeBoostMultiplier: Float
        var halationStrength: Float
        var halationRadiusFraction: Float
        var halationTint: SIMD3<Float>
        /// Halation onset, as three dials. The shipping paths read the stage's
        /// authored onsets; the sheet varies them on one frame so a value can be
        /// judged before it is authored anywhere.
        /// Per-layer halation onsets, in stops above diffuse white, in the
        /// DELIVERED picture's scale. Seeded from the stage so the dials open on
        /// the shipping look; a shipping path reads the stage's constants.
        var halationRedOnsetStops: Float
        var halationGreenOnsetStops: Float
        var halationBlueOnsetStops: Float
        var glowStrength: Float
        /// Lens diffusion node: preset radius ladder plus its blend amount.
        /// Off by default, so the sheet opens on the stock's shipping look.
        var diffusion: DiffusionSettings

        /// Seed every dial from a stock so the debug sheet opens on the shipping
        /// look for that stock.
        init(config: FilmStockConfig) {
            self.stockConfig = config
            let gauge = config.effectivePrintGauge
            self.gauge = gauge
            self.stockGrainSize = config.grainSize
            self.sizeMultiplier = gauge.sizeMultiplier
            self.presenceMultiplier = gauge.amplitudeMultiplier
            self.edgeBoostMultiplier = config.effectiveRecipe.edgeBoostMultiplier
            self.halationStrength = config.effectiveHalationStrength
            self.halationRadiusFraction = config.halationRadiusFraction
            self.halationTint = config.halationTint
            self.halationRedOnsetStops = SpatialEffectsStage.authoredOnsets.x
            self.halationGreenOnsetStops = SpatialEffectsStage.authoredOnsets.y
            self.halationBlueOnsetStops = SpatialEffectsStage.authoredOnsets.z
            self.glowStrength = config.glowStrength
            self.diffusion = config.effectiveDiffusion
        }

        /// Re-seed grain, halation and diffusion from a gauge's authored values.
        /// The gauge owns all of them, so switching format cannot leave a stale
        /// radius or amount behind from the previous one.
        mutating func applyGauge(_ gauge: PrintGauge) {
            self.gauge = gauge
            sizeMultiplier = gauge.sizeMultiplier
            presenceMultiplier = gauge.amplitudeMultiplier
            halationStrength = stockConfig.halationStrength(for: gauge)
            diffusion = gauge.diffusion
        }

        var gaugeAmplitude: Float { presenceMultiplier }

        /// Realized grain footprint the kernel will use (stock size × the size
        /// dial, clamped off the 128³ volume's undersampled floor).
        var realizedFootprint: Float {
            GrainModel.effectiveSize(stockGrainSize: stockGrainSize,
                                     sizeMultiplier: sizeMultiplier)
        }

        /// Realized grain amount at an edge factor of 1: base amount scaled by the
        /// gauge's presence multiplier. No ISO term — the gauge owns loudness.
        var realizedAmount: Float {
            GrainModel.baseAmount * gaugeAmplitude
        }
    }

    /// One rendered debug frame: numeric Rec.709-primary / gamma-2.4 BGRA8
    /// film output, NOT directly drawable sRGB. The sheet explicitly converts it
    /// through FilmOutputDisplayConverter; numeric/effect tests read it unchanged.
    struct DebugFrameRender {
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
        /// The source frame's own highlight ceiling in stops above diffuse white,
        /// measured from its code values. An empty halation mask is usually a fact
        /// about this number — nothing in the frame reaches the onset — so the
        /// sheet reports it beside the onset dial instead of leaving halation
        /// looking broken.
        let peakStopsAboveWhite: Float?
        var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
        var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
    }

    /// Render ONE frozen frame through the same pass1 → spatial → pass2 chain the
    /// video path uses, with grain/halation/glow supplied per call. Nothing here
    /// touches `render(...)` or the recorder: the debug sheet calls this once per
    /// (debounced) slider change and draws the result.
    ///
    /// `pixelBuffer` must contain Apple Wide Gamut / Apple Log 2 CODE values in
    /// RGBA-half storage. The debug source adapter decodes SDR idle into that
    /// domain; storage alone does not establish it. Returns nil on stage failure.
    func renderDebugFrame(
        pixelBuffer: CVPixelBuffer,
        config: FilmStockConfig,
        parameters: DebugFrameParameters,
        frameIndex: UInt32 = 0
    ) -> DebugFrameRender? {
        renderQueue.sync {
            // Load the stock's LUT once per stock so a drag does not re-parse a
            // 33³ .cube file on every frame. The video path is untouched.
            if debugLUTName != config.lutName {
                guard (try? loadLUT(named: config.lutName)) != nil, lutTexture != nil else { return nil }
                debugLUTName = config.lutName
            }
            guard let lut = lutTexture else { return nil }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else { return nil }
            guard let profile = RenderInputColorProvenance.profile(of: pixelBuffer) ?? (allowsSyntheticInputForTests ? .appleLog2 : nil) else {
                return nil
            }
            guard let spatialStage,
                  let sourceTexture = preparedSource(pixelBuffer,
                      expectedProfile: profile) else {
                return nil
            }

            // Same order the video path uses: halation on the scene-linear
            // source BEFORE the LUT, then the LUT + output contrast, then glow,
            // then grain. Keep the source's CVMetalTexture alive across the
            // halation and LUT passes, both of which read it.
            // The debug sheet must show the same curve the render applies, so the
            // ceiling comes from the frame on screen, not the authored 12x
            // fallback. A single frame IS the whole picture here, so measuring it
            // per frame is the right granularity (the take path measures once).
            // Always measured: the sheet reports it. An empty halation mask is
            // usually a fact about the frame's headroom rather than about the
            // dials, and nothing else in the sheet can tell the two apart.
            let measuredCeiling = PushPullTransfer.measuredHighlightCeiling(
                peakCodes: profile == .hlgBT2020 ? peakCodes(of: sourceTexture.texture) : Self.peakCodes(of: pixelBuffer))
            let highlightCeiling: Float? = config.effectivePushPull.isNeutral ? nil : measuredCeiling

            return withExtendedLifetime(sourceTexture.cvTexture) { () -> DebugFrameRender? in
                guard let halated = spatialStage.applyHalation(
                    source: sourceTexture.texture,
                    commandQueue: commandQueue,
                    strength: parameters.halationStrength,
                    radiusFraction: parameters.halationRadiusFraction,
                    layerScale: parameters.halationTint,
                    diffusion: parameters.diffusion,
                    // The onsets are dials on this sheet only; the shipping
                    // paths read the stage's constants. They open on those
                    // constants, so a value worth keeping can be pasted
                    // straight into them.
                    authoredOnsets: SIMD3(parameters.halationRedOnsetStops,
                                          parameters.halationGreenOnsetStops,
                                          parameters.halationBlueOnsetStops),
                    // The pull is applied HERE, in front of the emulsion, so the
                    // halo is measured against the light the film receives. The
                    // LUT pass below therefore grades with no exposure of its own.
                    highlightCeiling: highlightCeiling,
                    exposureStops: Float(config.effectivePushPull.stops.stops),
                    // The stop the camera captured under, put back after the
                    // emulsion. Flat, and applied before the LUT below.
                    postEmulsionStops: SystemExposureScheme.developLiftStops,
                    width: width,
                    height: height
                ) else { return nil }

                guard let graded = runLUTPass(
                    input: halated,
                    lut: lut,
                    outputContrast: config.outputContrast,
                    width: width,
                    height: height
                ) else { return nil }

                guard let glowed = spatialStage.applyGlow(
                    graded: graded,
                    commandQueue: commandQueue,
                    strength: parameters.glowStrength,
                    width: width,
                    height: height
                ) else { return nil }

                guard let outputBuffer = makeDebugOutputBuffer(width: width, height: height),
                      let outputTexture = makeTexture(from: outputBuffer, format: .bgra8Unorm)?.texture else {
                    return nil
                }

                guard runPass2(
                    inputTexture: glowed,
                    outputPixelBuffer: outputBuffer,
                    frameIndex: frameIndex,
                    iso: config.defaultISO,
                    grainSize: parameters.realizedFootprint,
                    edgeBoostMultiplier: parameters.edgeBoostMultiplier,
                    gaugeAmplitude: parameters.gaugeAmplitude,
                    width: width,
                    height: height
                ) else { return nil }

                return DebugFrameRender(texture: outputTexture, pixelBuffer: outputBuffer,
                                        peakStopsAboveWhite: measuredCeiling.map { log2($0) })
            }
        }
    }

    /// BGRA8, Metal-compatible output buffer for a debug frame — the same layout
    /// pass2 writes into the video path's writer adaptor pool.
    private func makeDebugOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
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
        try PhotoCubeLUT.parse(content)
    }

    /// Upload Resolve .cube RGB triplets to a 3D Metal texture (RGBA).
    private func createLUTTexture(size: Int, values: [Float]) throws {
        lutTexture = nil

        guard let texture = FilterableLUTTexture.make(device: device, size: size, rgba: values) else {
            throw RenderError.textureCreationFailed
        }
        lutTexture = texture
    }

    // MARK: - Frame Processing

    private func processFrames(
        videoProvider: ReadySampleProvider,
        videoReceiver: AVAssetWriterInput.PixelBufferReceiver,
        config: FilmStockConfig,
        delivery: DeliveryFraming.Delivery,
        /// The take's measured highlight ceiling, applied as the push/pull hold.
        highlightCeiling: Float?,
        // The audio lane is handed to a concurrent child task, so this call
        // takes ownership of it: `sending` is what lets the child task carry
        // these non-`Sendable` AVFoundation objects across the isolation
        // boundary without an unsafe escape hatch.
        audioProvider: sending ReadySampleProvider?,
        audioReceiver: sending AVAssetWriterInput.SampleBufferReceiver?,
        cancellationHandle: RenderCancellationHandle,
        grainPairing: GrainPairing,
        captureFirstBufferEvidence: Bool,
        progress: (@Sendable (Double) -> Void)?,
        progressRange: CMTimeRange,
        sourceProfile: CameraSourceProfile,
        /// The transport ramp for this render: the leader and trailer frames to
        /// add and the burn each end of the take carries.
        lightLeak: LightLeakTransport,
        /// One frame of the take, so the ramp and the added frames can be placed
        /// on the delivered timeline.
        frameDuration: CMTime,
        /// How many frames the take holds, for the tail's ramp.
        takeFrameCount: Int,
        /// Whether the clip opens with a frame of the take at its metered
        /// exposure, ahead of the black film.
        leadsWithNominalFrame: Bool
    ) async throws -> (counters: RenderDiagnosticsManifest.Counters,
                       firstBufferEvidence: RenderDiagnosticsManifest.DecodedBufferEvidence?) {
        guard let lut = renderQueue.sync(execute: { lutTexture }) else {
            throw RenderError.missingResource("LUT texture not loaded")
        }

        var counters = RenderDiagnosticsManifest.Counters()
        var firstBufferEvidence: RenderDiagnosticsManifest.DecodedBufferEvidence?
        var videoFailure: Error?
        let audioResult = AudioCopyResultBox()

        // The audio passthrough lane runs concurrently with the video lane.
        // AVAssetWriter will not hand out more video buffers while it is still
        // waiting on another input, so the audio lane must make progress
        // alongside the video lane or the writer deadlocks.
        //
        // The task is created here, before the cancellation handler, so it is
        // born in this function's own nonisolated context; the handler's
        // operation closure is `isolated(any)`, and spawning a concurrent child
        // from there would be rejected as a data race by region isolation.
        let audioCopy = Task {
            await copyAudioSamples(
                from: audioProvider,
                to: audioReceiver,
                result: audioResult,
                cancellationHandle: cancellationHandle
            )
        }

        // The film is running before the take: the leader goes in front of it on
        // the delivered timeline. Its timestamps sit under the trim origin, which
        // is where the writer's session starts (see `renderInternally`), so the
        // take's own frames — and its sound — stay exactly where the reader put
        // them.
        let leaderStart = CMTimeSubtract(progressRange.start,
                                         CMTimeMultiply(frameDuration, multiplier: Int32(lightLeak.leaderCount)))
        /// The frame ahead of the film, at the position the writer's session
        /// starts from.
        let posterTime = CMTimeSubtract(leaderStart, frameDuration)

        return try await withTaskCancellationHandler {
            // These mutable values are owned exclusively by this task.
            var frameIndex: UInt32 = 0
            var firstFrame = true
            /// Where the take's own last frame landed, so the trailer can run on
            /// from there.
            var lastFrameTime: CMTime?
            // The provider is non-`Sendable`; the box carries it into the raced
            // read task without requiring an unsafe transfer of the provider
            // itself. The provider is only read by one task at a time.
            let videoProviderBox = ReadProviderBox(videoProvider)

            // Progress is derived from frame presentation times mapped onto the
            // selected range. The accumulator clamps, keeps the fraction
            // monotonic and throttles to whole percent steps, so the callback
            // never fires once per frame.
            var progressAccumulator = progress.map { _ in RenderProgressAccumulator(range: progressRange) }

            while true {
                if let audioFailure = audioResult.getFailure {
                    videoFailure = audioFailure
                    break
                }
                if Task.isCancelled || cancellationHandle.writerStatus == .cancelled {
                    videoFailure = CancellationError()
                    break
                }

                // Read first so writer backpressure cannot hide reader EOF.
                // The read is raced against the cancellation gate: a wedged
                // reader can leave this `next()` suspended forever, and only
                // the gate — not reader cancellation — is guaranteed to release
                // the loop.
                let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
                do {
                    let sampleBox = SampleBox<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?>()
                    try await raceAgainstCancellation(gate: cancellationHandle.cancellationGate) {
                        sampleBox.set(try await videoProviderBox.provider.next())
                    }
                    sample = sampleBox.value.flatMap { $0 }
                } catch {
                    videoFailure = cancellationHandle.writerStatus == .cancelled
                        ? CancellationError()
                        : RenderError.readerFailed(cancellationHandle.videoReaderError ?? error)
                    break
                }
                guard let sample else {
                    // The take ends, the film does not: the trailer runs on past
                    // the last exposed frame, which is why it is written here —
                    // before the receiver is finished.
                    if cancellationHandle.videoReaderStatus == .completed, lightLeak.trailerCount > 0 {
                        do {
                            let last = lastFrameTime ?? progressRange.end
                            for step in 1...lightLeak.trailerCount {
                                let time = CMTimeAdd(last,
                                                     CMTimeMultiply(frameDuration, multiplier: Int32(step)))
                                try await appendFilmFrame(to: videoReceiver, at: time,
                                                          cancellationHandle: cancellationHandle)
                            }
                        } catch {
                            videoFailure = error
                        }
                    }
                    // End of video. A reader that stopped for any reason other
                    // than reaching the end of its range is a failure.
                    switch cancellationHandle.videoReaderStatus {
                    case .completed:
                        videoReceiver.finish()
                    case .failed:
                        videoFailure = RenderError.readerFailed(cancellationHandle.videoReaderError)
                    case .cancelled:
                        videoFailure = CancellationError()
                    default:
                        videoFailure = RenderError.stageFailed("video-reader", "Video ended before the reader completed.")
                    }
                    break
                }
                counters.decoded += 1

                let isFirstFrame = firstFrame
                firstFrame = false

                // Process: input → pass1 (LUT) → spatial halation/glow → pass2 (grain) → output
                do {
                    // frameIndex stays the render-loop index (diagnostics and
                    // failure injection); only the grain kernel sees the derived
                    // grain index, so an .daylight60 take shares one realization
                    // per pair while motion and PTS stay 60 fps.
                    let grainIndex = GrainPairingPolicy.grainIndex(frameIndex: frameIndex,
                                                                   pairing: grainPairing)
                    // The transport's burn is a fact about WHICH frame this is:
                    // the take's first frames are over-exposed while the film is
                    // still coming up to speed, and its last while it comes to
                    // rest.
                    let leak = lightLeak.frame(atFrame: Int(frameIndex), ofFrameCount: takeFrameCount)
                    let context = FrameRenderContext(
                        receiver: videoReceiver,
                        config: config,
                        delivery: delivery,
                        lut: lut,
                        cancellationHandle: cancellationHandle,
                        highlightCeiling: highlightCeiling,
                        sourceProfile: sourceProfile
                    )
                    // The head of the film is written once the first take frame has
                    // been read, because the clip's own first frame is made from
                    // it: the take at the exposure the camera metered it at, with
                    // the burn the transport put on it removed. It is a delivery
                    // decision rather than a mechanical one — see
                    // `LightLeakTransport.opensWithNominalFrame` — and it is what
                    // makes the take identifiable in Photos and in a preview grid.
                    // The writer takes frames in order, so this comes before the
                    // black film and the take.
                    if isFirstFrame {
                        if leadsWithNominalFrame {
                            _ = try await renderFrame(
                                sample: sample,
                                leak: .none,
                                context: context,
                                frameIndex: frameIndex,
                                grainIndex: grainIndex,
                                captureEvidence: false,
                                outputTime: posterTime
                            )
                        }
                        // The film is running before the take: unexposed frames
                        // ahead of it, at the positions the writer's session starts
                        // from (see `renderInternally`), so the take's own frames —
                        // and its sound — stay exactly where the reader put them.
                        for index in 0..<lightLeak.leaderCount {
                            let time = CMTimeAdd(leaderStart,
                                                 CMTimeMultiply(frameDuration, multiplier: Int32(index)))
                            try await appendFilmFrame(to: videoReceiver, at: time,
                                                      cancellationHandle: cancellationHandle)
                        }
                    }
                    let evidence = try await renderFrame(
                        sample: sample,
                        leak: leak,
                        context: context,
                        frameIndex: frameIndex,
                        grainIndex: grainIndex,
                        captureEvidence: captureFirstBufferEvidence && isFirstFrame
                    )
                    if let evidence { firstBufferEvidence = evidence }
                } catch {
                    videoFailure = audioResult.getFailure ?? error
                    break
                }

                counters.processed += 1
                counters.appended += 1
                lastFrameTime = sample.presentationTimeStamp
                if let progress,
                   let fraction = progressAccumulator?.fraction(forAppendedSeconds: sample.presentationTimeStamp.seconds) {
                    progress(fraction)
                }
                frameIndex += 1
            }

            if videoFailure != nil {
                // Cancel writer/reader to release an audio worker blocked on
                // writer backpressure, then join it before returning.
                cancellationHandle.cancel()
            }
            await audioCopy.value

            if let videoFailure {
                // An audio-lane failure is the real cause when both lanes stopped.
                // The audio lane calls cancel() on failure, which surfaces here as
                // a bare CancellationError and would otherwise mask the error that
                // actually stopped the render (e.g. an audio-append rejection).
                if videoFailure is CancellationError, let audioFailure = audioResult.getFailure {
                    throw audioFailure
                }
                throw videoFailure
            } else if let audioFailure = audioResult.getFailure {
                throw audioFailure
            } else if cancellationHandle.videoReaderStatus == .failed {
                throw RenderError.readerFailed(cancellationHandle.videoReaderError)
            } else if cancellationHandle.videoReaderStatus != .completed {
                throw CancellationError()
            } else if cancellationHandle.audioReaderStatus == .failed {
                throw RenderError.readerFailed(cancellationHandle.audioReaderError)
            } else {
                return (counters, firstBufferEvidence)
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

    /// The take's own highlight ceiling, in scene-light units.
    ///
    /// Sampled from the SAME decode contract as the render — Apple Log 2 codes
    /// at 64RGBAHalf, no AVFoundation colour conversion — so the numbers are the
    /// ones the push/pull curve will see. A handful of frames spread over the
    /// render range, every pixel's peak channel, then one pooled percentile
    /// (`PushPullTransfer.measuredHighlightCeiling`).
    ///
    /// Returns nil on ANY failure. An unreadable sample is not a reason to fail a
    /// render: the caller falls back to the authored 12x ceiling, and a take that
    /// cannot be sampled keeps the behaviour it had before this measurement
    /// existed.
    /// Internal so the sampling itself can be exercised against a real movie
    /// (`TakeHighlightCeilingTests`); nothing outside this file calls it.
    static func measureHighlightCeiling(asset: AVURLAsset,
                                        track: AVAssetTrack,
                                        range: CMTimeRange,
                                        sourceProfile: CameraSourceProfile = .appleLog2,
                                        peakCodeAdapter: (@Sendable (CVPixelBuffer) -> [Float])? = nil) async -> Float? {
        let seconds = range.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let sampleCount = 8
        // Ask for a small frame; the stride in `peakCodes` bounds the work even
        // if the reader hands back the native one.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: sourceProfile == .hlgBT2020
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: 256,
            kCVPixelBufferHeightKey as String: 256
        ]
        var peaks: [Float] = []
        peaks.reserveCapacity(sampleCount * 65_536)
        for index in 0..<sampleCount {
            // Mid-frame offsets: the first and last frames of a take are the most
            // likely to be a slate, a black leader or a ramp.
            let offset = (Double(index) + 0.5) / Double(sampleCount) * seconds
            let start = CMTimeAdd(range.start, CMTime(seconds: offset, preferredTimescale: 600))
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { return nil }
            let provider = reader.outputProvider(for: output)
            reader.timeRange = CMTimeRange(start: start,
                                           duration: CMTime(seconds: 0.5, preferredTimescale: 600))
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            guard let sample = try? await provider.next() else { return nil }
            sample.withUnsafeSampleBuffer { sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                peaks.append(contentsOf: peakCodeAdapter?(pixelBuffer) ?? Self.peakCodes(of: pixelBuffer))
            }
        }
        return PushPullTransfer.measuredHighlightCeiling(peakCodes: peaks)
    }

    /// Measure HLG only AFTER the production scene/gamut/Log2 adapter, so
    /// push/pull's measured highlight hold sees the same domain as the emulsion.
    private func peakCodes(of texture: MTLTexture) -> [Float] {
        let bytesPerRow = ((texture.width * 8 + 255) / 256) * 256
        guard texture.pixelFormat == .rgba16Float,
              let readback = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
              let command = commandQueue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return [] }
        let words = readback.contents().assumingMemoryBound(to: UInt16.self)
        let step = max(1, Int((Double(texture.width) * Double(texture.height) / 65_536).squareRoot().rounded(.up)))
        var peaks: [Float] = []
        for y in stride(from: 0, to: texture.height, by: step) {
            for x in stride(from: 0, to: texture.width, by: step) {
                let index = y * bytesPerRow / 2 + x * 4
                peaks.append(max(Float(Float16(bitPattern: words[index])),
                                 max(Float(Float16(bitPattern: words[index + 1])),
                                     Float(Float16(bitPattern: words[index + 2])))))
            }
        }
        return peaks
    }

    /// Every sampled pixel's peak channel, in Apple Log 2 code units.
    ///
    /// Strides the frame to a bounded pixel budget: a percentile does not need
    /// every pixel of a 12 MP frame, and the decoded buffer's size is the
    /// reader's to choose.
    private static func peakCodes(of pixelBuffer: CVPixelBuffer) -> [Float] {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let halfWordsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt16>.size
        let components = base.assumingMemoryBound(to: UInt16.self)
        let budget = 65_536
        let step = max(1, Int((Double(width) * Double(height) / Double(budget)).squareRoot().rounded(.up)))
        var peaks: [Float] = []
        peaks.reserveCapacity(budget + 1)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let index = y * halfWordsPerRow + x * 4
                let red = Float(Float16(bitPattern: components[index]))
                let green = Float(Float16(bitPattern: components[index + 1]))
                let blue = Float(Float16(bitPattern: components[index + 2]))
                peaks.append(max(red, max(green, blue)))
                x += step
            }
            y += step
        }
        return peaks
    }

    /// Append one unexposed frame: the film that ran behind the gate before the
    /// take was exposed, or that ran on after it was cut. There is nothing on it
    /// to grade, so it is written straight to the receiver's own pool as opaque
    /// black rather than through the stock's LUT — a leader is not a picture of
    /// black, it is the absence of a picture.
    ///
    /// It shares the shipping append path (including the test override and the
    /// cancellation gate) so a leader frame can neither outrun a cancel nor
    /// vanish from a render that counts its appends.
    private func appendFilmFrame(
        to receiver: AVAssetWriterInput.PixelBufferReceiver,
        at time: CMTime,
        cancellationHandle: RenderCancellationHandle
    ) async throws {
        guard let pool = receiver.pixelBufferPool else {
            if cancellationHandle.writerStatus == .cancelled { throw CancellationError() }
            throw RenderError.stageFailed("pixel-buffer-pool", "Writer pixel buffer pool is unavailable.")
        }
        var buffer: CVMutablePixelBuffer
        do {
            buffer = try pool.makeMutablePixelBuffer()
        } catch {
            if cancellationHandle.writerStatus == .cancelled { throw CancellationError() }
            throw RenderError.stageFailed("pixel-buffer-allocation",
                                          "Unable to allocate output pixel buffer (\(error)).")
        }
        buffer.withUnsafeBuffer { pixelBuffer in
            guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            // The pool is 32BGRA; opaque black is B=G=R=0, A=255, which in one
            // little-endian word is 0xFF000000.
            for row in 0..<height {
                let pixels = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt32.self)
                for column in 0..<(rowBytes / 4) { pixels[column] = 0xFF00_0000 }
            }
        }

        let appendGate = cancellationHandle.cancellationGate
        if appendGate.isSignalled || Task.isCancelled { throw CancellationError() }
        let appendInputs = RacedInputs((receiver: receiver,
                                        buffer: CVReadOnlyPixelBuffer(buffer),
                                        time: time))
        do {
            try await raceAgainstCancellation(gate: appendGate) {
                let inputs = appendInputs.value
                if let override = self.videoAppendOverride {
                    try await override(inputs.buffer, inputs.time)
                } else {
                    try await inputs.receiver.append(inputs.buffer, with: inputs.time)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || cancellationHandle.writerStatus == .cancelled {
                throw CancellationError()
            }
            throw RenderError.stageFailed("video-append", "The film frame could not be appended (\(error)).")
        }
    }

    /// Grade and encode a single frame: LUT pass, spatial halation/glow,
    /// grain pass, then append. Throws the stage failure to report, if any.
    ///
    /// The GPU passes are byte-for-byte the same as before the receiver
    /// migration; only the output buffer source (the receiver's pool) and the
    /// append call changed.
    private func renderFrame(
        sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
        leak: LightLeakFrame,
        context: FrameRenderContext,
        frameIndex: UInt32,
        grainIndex: UInt32,
        captureEvidence: Bool,
        /// Where the finished frame belongs on the delivered timeline. `nil` puts
        /// it at its own source time, which is every frame of the take; the one
        /// frame that is written ahead of the film is placed explicitly.
        outputTime: CMTime? = nil
    ) async throws -> RenderDiagnosticsManifest.DecodedBufferEvidence? {
        if let renderFailureAfterFrames, frameIndex >= renderFailureAfterFrames {
            throw RenderError.stageFailed("injected-frame-failure", "Synthetic writer failure after \(frameIndex) frames.")
        }
        let receiver = context.receiver
        let config = context.config

        // Cancellation can invalidate the receiver's pool after the frame loop's
        // cancellation check. Report that race as cancellation, not allocation
        // failure; a genuinely unavailable pool still reports its stage error.
        guard let pool = receiver.pixelBufferPool else {
            if Task.isCancelled || context.cancellationHandle.writerStatus == .cancelled {
                throw CancellationError()
            }
            throw RenderError.stageFailed("pixel-buffer-pool", "Writer pixel buffer pool is unavailable.")
        }
        let outputBuffer: CVMutablePixelBuffer
        do {
            outputBuffer = try pool.makeMutablePixelBuffer()
        } catch {
            if Task.isCancelled || context.cancellationHandle.writerStatus == .cancelled {
                throw CancellationError()
            }
            throw RenderError.stageFailed("pixel-buffer-allocation", "Unable to allocate output pixel buffer (\(error)).")
        }

        // The GPU passes and the LUT texture read stay confined to
        // `renderQueue`, exactly as before the migration, so they still
        // serialize with the debug single-frame path's `renderQueue.sync`.
        var evidence: RenderDiagnosticsManifest.DecodedBufferEvidence?
        let outcome: Result<Void, Error> = renderQueue.sync {
            sample.withUnsafeSampleBuffer { sampleBuffer in
                guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return .failure(RenderError.stageFailed("decode", "Sample buffer has no pixel buffer."))
                }
                let width = CVPixelBufferGetWidth(sourcePixelBuffer)
                let height = CVPixelBufferGetHeight(sourcePixelBuffer)
                if captureEvidence {
                    evidence = Self.snapshotDecodedBuffer(sourcePixelBuffer)
                }
                // The crop was resolved from the track's naturalSize; a decoded
                // frame of a different size would be written at the wrong
                // geometry, so refuse rather than crop the wrong rectangle.
                let delivery = context.delivery
                guard width == delivery.sourceWidth, height == delivery.sourceHeight else {
                    return .failure(RenderError.stageFailed(
                        "delivery-framing",
                        "Decoded frame is \(width)x\(height) but the delivery was resolved for "
                            + "\(delivery.sourceWidth)x\(delivery.sourceHeight)."))
                }
                let outputWidth = delivery.deliveredWidth
                let outputHeight = delivery.deliveredHeight
                return outputBuffer.withUnsafeBuffer { destination in
                    guard let spatialStage = self.spatialStage,
                          let sourceTexture = self.preparedSource(sourcePixelBuffer, expectedProfile: context.sourceProfile) else {
                        return .failure(RenderError.stageFailed("gpu-halation", "Could not wrap the decoded frame for halation."))
                    }
                    // Halation is added to the scene-linear source and re-encoded
                    // to Apple Log 2 BEFORE the LUT, so the scattered light is
                    // tone-mapped by the same stock curve as the source. Keep the
                    // source's CVMetalTexture alive across the halation and LUT
                    // passes, both of which read it.
                    return withExtendedLifetime(sourceTexture.cvTexture) { () -> Result<Void, Error> in
                        // Delivery framing is a geometry change only: the crop
                        // is taken once, here, from the decoded frame, and every
                        // pass downstream (halation, LUT, glow, grain) then runs
                        // at the delivered size on the cropped pixels. 16:9 has
                        // no crop, so this returns the decoded frame itself and
                        // the pass chain is unchanged.
                        guard let delivered = self.makeDeliverySource(sourceTexture.texture, delivery: delivery) else {
                            return .failure(RenderError.stageFailed(
                                "delivery-crop", "The delivery crop pass did not complete."))
                        }
                        guard let halated = spatialStage.applyHalation(
                            source: delivered,
                            commandQueue: self.commandQueue,
                            strength: config.effectiveHalationStrength,
                            radiusFraction: config.halationRadiusFraction,
                            layerScale: config.halationTint,
                            diffusion: config.effectiveDiffusion,
                            // A video take is locked to its shutter, so a bright
                            // day is over-exposed at the sensor and pulled down in
                            // the render. Applying that pull in front of the
                            // emulsion is the whole point: after halation, the
                            // frame came back darker with the halo of the light
                            // the sensor saw.
                            highlightCeiling: context.highlightCeiling,
                            exposureStops: Float(config.effectivePushPull.stops.stops),
                            postEmulsionStops: SystemExposureScheme.developLiftStops,
                            // The gate's leak at this point in the take, in the
                            // same pre-LUT scene light as the halo.
                            leak: leak,
                            // The delivered texture is already the crop, so the
                            // stage works in delivery pixels, not source pixels.
                            width: outputWidth,
                            height: outputHeight
                        ) else {
                            return .failure(RenderError.stageFailed("gpu-halation", "The halation stage did not complete."))
                        }

                        guard let graded = self.runLUTPass(
                            input: halated,
                            lut: context.lut,
                            outputContrast: config.outputContrast,
                            width: outputWidth,
                            height: outputHeight
                        ) else {
                            return .failure(RenderError.stageFailed("gpu-pass-1", "The LUT GPU pass did not complete."))
                        }

                        guard let glowed = spatialStage.applyGlow(
                            graded: graded,
                            commandQueue: self.commandQueue,
                            strength: config.glowStrength,
                            width: outputWidth,
                            height: outputHeight
                        ) else {
                            return .failure(RenderError.stageFailed("gpu-spatial", "The glow stage did not complete."))
                        }

                        let gauge = config.effectivePrintGauge
                        guard self.runPass2(
                            inputTexture: glowed,
                            outputPixelBuffer: destination,
                            frameIndex: grainIndex,
                            iso: config.defaultISO,
                            grainSize: GrainModel.effectiveSize(stockGrainSize: config.grainSize, gauge: gauge),
                            edgeBoostMultiplier: config.effectiveRecipe.edgeBoostMultiplier,
                            gaugeAmplitude: gauge.amplitudeMultiplier,
                            width: outputWidth,
                            height: outputHeight
                        ) else {
                            return .failure(RenderError.stageFailed("gpu-pass-2", "The grain GPU pass did not complete."))
                        }
                        return .success(())
                    }
                }
            }
        }
        try outcome.get()

        // A cancelled writer does NOT resume a pending append: a hosted run
        // entered this append after cancel() and it never returned, so the
        // render task was pinned exactly as the wedged read used to pin it.
        // Two guards: never start an append on a writer already asked to
        // cancel, and race the append itself so a cancel landing mid-append
        // cannot hang.
        let appendGate = context.cancellationHandle.cancellationGate
        if appendGate.isSignalled || Task.isCancelled {
            throw CancellationError()
        }
        // The append is raced exactly like the audio lane's, and the "the
        // buffer is move-only so it cannot cross into a raced task" claim was
        // wrong: the receiver's `append(_:with:)` takes a `CVReadOnlyPixelBuffer`
        // — a `Sendable` reference type — and the move-only `CVMutablePixelBuffer`
        // is consumed into it *before* the box is built, so the mutable buffer
        // itself never crosses a task boundary. Only the reused, non-`Sendable`
        // receiver needs the unchecked box, the same shape `copyAudioSamples`
        // already relies on. A cancel landing while the append waits on writer
        // backpressure now abandons the append (which keeps the buffer alive
        // until that call ever settles) instead of pinning the frame loop.
        let appendInputs = RacedInputs((receiver: receiver,
                                        buffer: CVReadOnlyPixelBuffer(outputBuffer),
                                        time: outputTime ?? sample.presentationTimeStamp))
        do {
            try await raceAgainstCancellation(gate: appendGate) {
                let inputs = appendInputs.value
                if let override = self.videoAppendOverride {
                    try await override(inputs.buffer, inputs.time)
                } else {
                    try await inputs.receiver.append(inputs.buffer, with: inputs.time)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || context.cancellationHandle.writerStatus == .cancelled {
                throw CancellationError()
            }
            throw RenderError.stageFailed(
                "writer-append",
                context.cancellationHandle.writerError?.localizedDescription ?? error.localizedDescription
            )
        }
        return evidence
    }

    /// Copies audio samples from the dedicated audio reader's provider to the
    /// writer's sample-buffer receiver, suspending on the receiver's async
    /// `append(_:)` until the writer can take each sample — the backpressure
    /// wait the old `isReadyForMoreMediaData` polling loop performed. The
    /// previous pre-polling loop called `append` while the input was not ready,
    /// which returned false and silently discarded samples (gaps/silent audio).
    ///
    /// Runs as a child task alongside the video lane. The audio input is marked
    /// finished as soon as the audio is exhausted.
    ///
    /// This must happen HERE, not in the video loop. Audio is a cheap
    /// passthrough while video frames go through three GPU passes, so the
    /// audio lane races far ahead of the video and reaches end-of-track
    /// long before the video does. AVAssetWriter will not hand out more
    /// video buffers while it is still waiting on another input, so leaving
    /// the audio input open deadlocked the writer: the video input never
    /// became ready, the frame loop timed out, and the render failed (or, on
    /// device, appeared to hang).
    private func copyAudioSamples(
        from audioProvider: ReadySampleProvider?,
        to audioReceiver: AVAssetWriterInput.SampleBufferReceiver?,
        result: AudioCopyResultBox,
        cancellationHandle: RenderCancellationHandle
    ) async {
        guard let audioProvider, let audioReceiver else {
            result.set(.success(()))
            return
        }

        let audioProviderBox = ReadProviderBox(audioProvider)
        var appendedSamples = 0
        do {
            while true {
                // Race the read against the cancellation gate: a wedged audio
                // reader can leave `next()` suspended forever, and only the gate
                // is guaranteed to release it.
                let sampleBox = SampleBox<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?>()
                try await raceAgainstCancellation(gate: cancellationHandle.cancellationGate) {
                    sampleBox.set(try await audioProviderBox.provider.next())
                }
                guard let sample = sampleBox.value.flatMap({ $0 }) else { break }
                // This lane is an unstructured task, so it does NOT inherit
                // cancellation: `Task.isCancelled` is always false here and the
                // gate is the only signal that can stop it.
                if cancellationHandle.cancellationGate.isSignalled {
                    throw CancellationError()
                }
                if let audioAppendRejectionAfterSamples, appendedSamples >= audioAppendRejectionAfterSamples {
                    throw RenderError.stageFailed("audio-append", "Synthetic audio append rejection.")
                }
                // Same writer-append hazard as the video lane: race it against
                // the gate so a cancelled writer cannot pin the audio lane and,
                // through `await audioCopy.value`, the whole render.
                let audioAppendInputs = RacedInputs((receiver: audioReceiver, sample: sample))
                try await raceAgainstCancellation(gate: cancellationHandle.cancellationGate) {
                    try await audioAppendInputs.value.receiver.append(audioAppendInputs.value.sample)
                }
                appendedSamples += 1
            }
            switch cancellationHandle.audioReaderStatus {
            case .completed:
                audioReceiver.finish()
                result.set(.success(()))
            case .failed:
                throw RenderError.readerFailed(cancellationHandle.audioReaderError)
            case .cancelled:
                throw CancellationError()
            default:
                throw RenderError.stageFailed("audio-reader", "Audio ended before the reader completed.")
            }
        } catch {
            result.set(.failure(error))
            cancellationHandle.cancel()
        }
    }

    // MARK: - GPU Passes

    /// Pass 1: grade the (halation-modified) Apple Log 2 frame through the stock
    /// LUT and output contrast. Returns the display-referred graded texture.
    ///
    /// `input` is Apple Log 2 — either the raw decoded frame, or the frame the
    /// halation stage re-encoded after adding scattered scene light. The LUT is
    /// authored for Apple Log 2 code values, so halation must be applied to the
    /// source BEFORE this pass, not to its output: a 2x and a 100x specular both
    /// land near 1.0 after the LUT, and the superwhite separation halation needs
    /// would be gone.
    ///
    /// The development push/pull is NOT applied here. It is a scene-light curve
    /// that belongs in FRONT of the emulsion, so `SpatialEffectsStage.applyHalation`
    /// runs it inside the halation ladder (`spatial_expose`) for both a take and a
    /// still: a truly clipped highlight then holds at white and keeps halating
    /// instead of being pulled into the stock's cast. This pass only grades.
    private func runLUTPass(
        input: MTLTexture,
        lut: MTLTexture,
        outputContrast: Float,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let intermediateTexture = makeIntermediateTexture(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        // `pass1_lut_halation_glow` still binds these two buffers for signature
        // stability, but halation and glow are spatial now and this pass only
        // grades, so they are pinned to zero.
        var halation: Float = 0
        var glow: Float = 0
        var contrast = outputContrast

        encoder.setComputePipelineState(pass1Pipeline!)
        encoder.setTexture(input, index: 0)
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

        guard commandBuffer.status == .completed else { return nil }
        return intermediateTexture
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
        gaugeAmplitude: Float,
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
            edgeBoostMultiplier: edgeBoostMultiplier, gaugeAmplitude: gaugeAmplitude
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

    /// Native HLG is adapted before halation and stock processing; the original
    /// remains HLG. An unknown/mismatched decoded source fails closed.
    private func preparedSource(_ buffer: CVPixelBuffer, expectedProfile: CameraSourceProfile) -> PixelBufferTexture? {
        if expectedProfile == .appleLog2 {
            let observed = RenderInputColorProvenance.profile(of: buffer)
            guard observed == .appleLog2 || (observed == nil && allowsSyntheticInputForTests),
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf else { return nil }
            return makeTexture(from: buffer, format: .rgba16Float)
        }
        guard RenderInputColorProvenance.profile(of: buffer) == .hlgBT2020,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2, let hlgPipeline, let textureCache,
              let output = makeIntermediateTexture(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var yRef: CVMetalTexture?
        var cRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .r16Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &yRef)
        let cStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .rg16Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &cRef)
        guard yStatus == kCVReturnSuccess, cStatus == kCVReturnSuccess,
              let yRef, let cRef, let y = CVMetalTextureGetTexture(yRef), let c = CVMetalTextureGetTexture(cRef) else {
            encoder.endEncoding()
            return nil
        }
        encoder.setComputePipelineState(hlgPipeline)
        encoder.setTexture(y, index: 0)
        encoder.setTexture(c, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime((yRef, cRef)) {}
        guard command.status == .completed else { return nil }
        return PixelBufferTexture(cvTexture: yRef, texture: output)
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

    /// The pixels the grade operates on: the decoded frame for a widescreen
    /// delivery, or the centred crop rectangle for a 4:3 delivery.
    ///
    /// The crop is a single GPU blit of the source region into a
    /// delivery-sized texture. Doing it once, before the first pass, means the
    /// colour chain is untouched: halation, the LUT, glow and grain all run at
    /// the delivered size over real pixels of the original, so the delivered
    /// file is a crop rather than a scaled copy of the whole frame.
    private func makeDeliverySource(_ source: MTLTexture,
                                    delivery: DeliveryFraming.Delivery) -> MTLTexture? {
        guard delivery.isCropped else { return source }
        guard let cropped = makeIntermediateTexture(width: delivery.deliveredWidth,
                                                    height: delivery.deliveredHeight),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: delivery.cropX, y: delivery.cropY, z: 0),
                  sourceSize: MTLSize(width: delivery.deliveredWidth,
                                      height: delivery.deliveredHeight, depth: 1),
                  to: cropped, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? cropped : nil
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
        hlgPipeline = try pipeline("hlg_prepare")
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

/// Pure, timestamp-driven fraction for a single render.
///
/// The fraction is derived from the presentation time of frames actually
/// appended to the writer, mapped onto the selected source/trim range — never
/// from a timer. It is clamped to `0...<1` and never decreases. Emissions are
/// throttled to whole percent steps so the progress callback is not driven once
/// per frame. The terminal `1` is reported separately by `finishFraction` only
/// once the writer has finished, so a short final frame time cannot look
/// complete before the file is written.
struct RenderProgressAccumulator: Sendable {
    /// Minimum change between reported fractions (one percent).
    static let step = 0.01
    /// The fraction reported once the writer has finished writing.
    static let finishFraction = 1.0

    private let startSeconds: Double
    private let durationSeconds: Double
    private var lastReported: Double = 0

    init(startSeconds: Double, durationSeconds: Double) {
        self.startSeconds = startSeconds.isFinite ? startSeconds : 0
        self.durationSeconds = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0
    }

    init(range: CMTimeRange) {
        self.init(startSeconds: range.start.seconds, durationSeconds: range.duration.seconds)
    }

    /// The fraction to report for a frame appended at `seconds` on the source
    /// timeline, or `nil` when the frame does not advance a whole percent step.
    mutating func fraction(forAppendedSeconds seconds: Double) -> Double? {
        guard durationSeconds > 0, seconds.isFinite else { return nil }
        let raw = (seconds - startSeconds) / durationSeconds
        // Keep frame-derived fractions strictly below 1: completion is
        // signalled only by `finishFraction`, once the writer has finished.
        let bounded = min(max(raw, 0), 1 - Self.step)
        guard bounded >= lastReported + Self.step - 1e-9 else { return nil }
        lastReported = bounded
        return bounded
    }
}

struct GrainUniforms {
    var frameIndex: UInt32
    var iso: Float
    var grainSize: Float
    var edgeBoostMultiplier: Float = 0
    var gaugeAmplitude: Float = 1.0
    /// Dye-cloud chroma strength; see `GrainModel.videoChromaAmount`. The video
    /// path takes the default, the still path overrides it.
    var chromaAmount: Float = GrainModel.videoChromaAmount
}

/// Everything one frame needs to be graded and appended, bundled so the frame
/// loop's per-frame helper keeps a manageable parameter list.
private struct FrameRenderContext {
    let receiver: AVAssetWriterInput.PixelBufferReceiver
    let config: FilmStockConfig
    /// The delivered geometry this frame is written at. A cropped delivery is
    /// resolved once per render, so every frame crops the same rectangle.
    let delivery: DeliveryFraming.Delivery
    let lut: MTLTexture
    let cancellationHandle: RenderCancellationHandle
    /// The take's own highlight ceiling, measured once for the whole render.
    /// Nil when the render is neutral (nothing to hold) or the sample failed.
    let highlightCeiling: Float?
    let sourceProfile: CameraSourceProfile
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

/// Carries a non-`Sendable` `AVAssetReaderOutput.Provider` into the task that
/// performs a raced read.
///
/// The unchecked sendability is sound **only** because of an invariant the call
/// sites must keep: *a lane never issues a new read after abandoning one*. Every
/// loop terminates on a race loss — the video frame loop breaks, the audio copy
/// lane throws out of its loop — so a stale abandoned `next()` can never run
/// concurrently with a new read on the same provider. Retrying a read after a
/// gate win would silently turn this into a real data race on a non-`Sendable`
/// type. Keep that invariant if you change either loop.
///
/// Boxing (rather than transferring) the provider also matters: the loops reuse
/// it across iterations, so it cannot be consumed via `sending`.
final class ReadProviderBox: @unchecked Sendable {
    let provider: ReadySampleProvider

    init(_ provider: ReadySampleProvider) {
        self.provider = provider
    }
}

/// Serializes reader/writer cancellation against the status and error reads
/// the frame loop and the audio lane poll. Sample transport itself no longer
/// needs a lane lock: `AVAssetReaderOutput.Provider.next()` and the writer
/// receivers' `append(_:)` are concurrency-safe and are driven from structured
/// child tasks rather than from a shared serial queue.
final class RenderCancellationHandle: @unchecked Sendable {
    private let writer: AVAssetWriter?
    private let videoReader: AVAssetReader?
    private let audioReader: AVAssetReader?
    private let writerLock = NSLock()
    private let videoReaderLock = NSLock()
    private let audioReaderLock = NSLock()

    /// The explicit release signal the render loop races every provider read
    /// against. It is the only release that is guaranteed to un-park a read the
    /// readers have wedged on, so `cancel()` signals it.
    let cancellationGate = CancellationGate()

    init(writer: AVAssetWriter?, videoReader: AVAssetReader?, audioReader: AVAssetReader?) {
        self.writer = writer
        self.videoReader = videoReader
        self.audioReader = audioReader
    }

    func cancel() {
        // Signal the gate first. Cancelling the writer releases receiver
        // backpressure and cancelling each reader stops the decode, but neither
        // reliably resumes a pending provider `next()` — a wedged reader can
        // leave it suspended forever — so the gate is what actually releases a
        // blocked read.
        cancellationGate.signal()

        if let writer {
            writerLock.lock()
            writer.cancelWriting()
            writerLock.unlock()
        }

        if let videoReader {
            videoReaderLock.lock()
            videoReader.cancelReading()
            videoReaderLock.unlock()
        }

        if let audioReader {
            audioReaderLock.lock()
            audioReader.cancelReading()
            audioReaderLock.unlock()
        }
    }

    var videoReaderStatus: AVAssetReader.Status {
        guard let videoReader else { return .unknown }
        videoReaderLock.lock()
        defer { videoReaderLock.unlock() }
        return videoReader.status
    }

    var videoReaderError: Error? {
        guard let videoReader else { return nil }
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
        guard let writer else { return .unknown }
        writerLock.lock()
        defer { writerLock.unlock() }
        return writer.status
    }

    var writerError: Error? {
        guard let writer else { return nil }
        writerLock.lock()
        defer { writerLock.unlock() }
        return writer.error
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
