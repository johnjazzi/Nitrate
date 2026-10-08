import AVFoundation
@preconcurrency import Metal
import CoreVideo

/// AD-6: Metal GPU pipeline — hybrid 2-pass post-record render.
/// Pass 1: LUT + halation + glow (single fused Metal compute shader).
/// Pass 2: 3D noise volume grain with temporal coherence (AD-9).
/// Input: .mov URL (Apple Log, HEVC H.265, 4K, 24fps).
/// Output: .mov URL (HEVC H.265, 4K, ~36 Mbps).
final class PipelineRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderQueue = DispatchQueue(label: "pipeline.render")

    // Cached pipeline states
    private var pass1Pipeline: MTLComputePipelineState?
    private var pass2Pipeline: MTLComputePipelineState?
    private var grainTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?

    // Current LUT texture (loaded per-render based on stock config)
    private var lutTexture: MTLTexture?

    init() throws {
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
        trimRange: CMTimeRange? = nil
    ) async throws -> URL {
        // Load the LUT for this stock
        try loadLUT(named: config.lutName)

        let asset = AVAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }

        // Audio passthrough: copy audio track unchanged
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = audioTracks.first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        let renderWidth = naturalSize.width
        let renderHeight = naturalSize.height

        // Use naturalSize everywhere — encoded dimensions, never swapped.
        // Rotation is preserved via writerInput.transform below.
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: renderWidth,
            kCVPixelBufferHeightKey as String: renderHeight
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        reader.timeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)

        // Audio reader + writer (passthrough)
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioWriterInput: AVAssetWriterInput?
        if let audioTrack = audioTrack {
            audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioReaderOutput?.alwaysCopiesSampleData = false
            reader.add(audioReaderOutput!)
        }

        // Writer setup
        let outputURL = tempOutputURL()
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: 72_000_000,
            AVVideoMaxKeyFrameIntervalKey: 48,
            AVVideoExpectedSourceFrameRateKey: nominalFrameRate,
            AVVideoAllowFrameReorderingKey: false
        ]

        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: videoCompression
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        // Writer adaptor: BGRA 8-bit. After LUT, output is SDR in [0,1] — 8-bit is fine.
        // HEVC encoder expects BGRA (converts to Y′CbCr internally).
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

        writer.add(writerInput)

        // Audio passthrough writer input
        // nil outputSettings + sourceFormatHint = pass compressed audio straight through
        if let audioTrack = audioTrack {
            let audioDesc = try await audioTrack.load(.formatDescriptions).first
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                                  sourceFormatHint: audioDesc)
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
            audioWriterInput = audioInput
        }

        guard writer.startWriting() else {
            throw RenderError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error)
        }

        // Process video frames + audio passthrough
        try await processFrames(
            readerOutput: readerOutput,
            adaptor: adaptor,
            writerInput: writerInput,
            writer: writer,
            config: config,
            frameRate: nominalFrameRate,
            audioReaderOutput: audioReaderOutput,
            audioWriterInput: audioWriterInput
        )

        // Finalize
        writerInput.markAsFinished()
        await writer.finishWriting()

        if let error = writer.error {
            throw RenderError.writerFailed(error)
        }

        return outputURL
    }

    // MARK: - LUT Loading

    /// Parse a .cube LUT file and load it as a 3D Metal texture.
    private func loadLUT(named filename: String) throws {
        guard let path = findBundleFile(named: filename) ??
                Bundle.main.path(forResource: filename.replacingOccurrences(of: ".cube", with: ""),
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

        guard size > 0, !values.isEmpty else {
            throw RenderError.invalidLUTData
        }

        return (size, values)
    }

    /// Upload parsed LUT values to a 3D Metal texture (RGBA). Reversed z-order for Metal.
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

        // .cube data: BGR order, z-increment fastest (outer loop over B).
        // Metal samples with normalized coords (r,g,b) where r→x, g→y, b→z.
        // Reorder BGR→RGB and flip layout for Metal's slice ordering.
        var reordered: [Float] = []
        reordered.reserveCapacity(size * size * size * 4)
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    let idx = (r * size * size + g * size + b) * 4
                    reordered.append(values[idx + 2]) // B → R
                    reordered.append(values[idx + 1]) // G → G
                    reordered.append(values[idx])     // R → B
                    reordered.append(values[idx + 3]) // A
                }
            }
        }

        reordered.withUnsafeBytes { ptr in
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
        readerOutput: AVAssetReaderTrackOutput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writerInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        config: FilmStockConfig,
        frameRate: Float,
        audioReaderOutput: AVAssetReaderTrackOutput?,
        audioWriterInput: AVAssetWriterInput?
    ) async throws {
        let pass1State = pass1Pipeline!
        let pass2State = pass2Pipeline!
        guard let lut = lutTexture else {
            throw RenderError.missingResource("LUT texture not loaded")
        }

        var frameIndex: UInt = 0
        var firstFrame = true
        var actualWidth = 0
        var actualHeight = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // Start audio passthrough on a parallel queue
                let audioDone: DispatchWorkItem? = {
                    guard let audioReader = audioReaderOutput,
                          let audioWriter = audioWriterInput else { return nil }
                    let work = DispatchWorkItem {
                        while audioWriter.isReadyForMoreMediaData || writer.status == .writing {
                            guard let sample = audioReader.copyNextSampleBuffer() else { break }
                            audioWriter.append(sample)
                        }
                        audioWriter.markAsFinished()
                    }
                    DispatchQueue.global(qos: .utility).async(execute: work)
                    return work
                }()

                while writerInput.isReadyForMoreMediaData || writer.status == .writing {
                    // Wait until the writer input is ready or writer fails
                    var pollCount = 0
                    while !writerInput.isReadyForMoreMediaData {
                        if writer.status == .failed || writer.status == .cancelled {
                            continuation.resume(throwing: RenderError.writerFailed(writer.error))
                            return
                        }
                        usleep(1000)
                        pollCount += 1
                        if pollCount > 5000 {  // 5s timeout
                            continuation.resume(throwing: RenderError.writerFailed(nil))
                            return
                        }
                    }

                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        break
                    }

                    guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        continue
                    }
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    if firstFrame {
                        actualWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
                        actualHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
                        firstFrame = false
                    }

                    // Get an output pixel buffer from the adaptor's pool
                    var outputPixelBuffer: CVPixelBuffer?
                    let pool = adaptor.pixelBufferPool!
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)

                    guard let outBuf = outputPixelBuffer else { continue }

                    // Process: input → pass1 → intermediate → pass2 → output
                    let pass1Output = self.runPass1(
                        sourcePixelBuffer: sourcePixelBuffer,
                        lut: lut,
                        halationStrength: config.halationStrength,
                        glowStrength: config.glowStrength,
                        width: actualWidth,
                        height: actualHeight
                    )

                    guard let intermediateTexture = pass1Output else { continue }

                    let pass2Output = self.runPass2(
                        inputTexture: intermediateTexture,
                        outputPixelBuffer: outBuf,
                        frameIndex: frameIndex,
                        iso: config.defaultISO,
                        grainSize: config.grainSize,
                        width: actualWidth,
                        height: actualHeight
                    )

                    guard pass2Output else { continue }

                    // Append processed frame
                    adaptor.append(outBuf, withPresentationTime: timestamp)
                    frameIndex += 1
                }

                // Wait for audio passthrough to complete before continuing
                audioDone?.wait()
                audioWriterInput?.markAsFinished()

                continuation.resume()
            }
        }
    }

    // MARK: - GPU Passes

    /// Pass 1: LUT + halation + glow. Returns the intermediate Metal texture.
    private func runPass1(
        sourcePixelBuffer: CVPixelBuffer,
        lut: MTLTexture,
        halationStrength: Float,
        glowStrength: Float,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        // Create source texture from CVPixelBuffer via texture cache
        guard let sourceTexture = makeTexture(from: sourcePixelBuffer, format: .rgba16Float),
              let intermediateTexture = makeIntermediateTexture(width: width, height: height) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var halation = halationStrength
        var glow = glowStrength

        encoder.setComputePipelineState(pass1Pipeline!)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(intermediateTexture, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setBytes(&halation, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&glow, length: MemoryLayout<Float>.size, index: 1)

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

        return intermediateTexture
    }

    /// Pass 2: grain. Writes result directly into the output pixel buffer.
    /// Returns true on success.
    private func runPass2(
        inputTexture: MTLTexture,
        outputPixelBuffer: CVPixelBuffer,
        frameIndex: UInt,
        iso: Float,
        grainSize: Float,
        width: Int,
        height: Int
    ) -> Bool {
        guard let outputTexture = makeTexture(from: outputPixelBuffer, format: .bgra8Unorm) else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        var uniforms = GrainUniforms(frameIndex: frameIndex, iso: iso, grainSize: grainSize)

        encoder.setComputePipelineState(pass2Pipeline!)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
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

        return true
    }

    // MARK: - Texture Helpers

    /// Create a Metal texture from a CVPixelBuffer using the texture cache.
    private func makeTexture(from pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
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

        guard let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
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
        // Xcode compiles .metal files into default.metallib at build time.
        // Source .metal files are not in the bundle.
        let library = try device.makeDefaultLibrary(bundle: Bundle.main)

        guard let pass1 = library.makeFunction(name: "pass1_lut_halation_glow") else {
            throw RenderError.missingFunction("pass1_lut_halation_glow")
        }
        guard let pass2 = library.makeFunction(name: "pass2_grain") else {
            throw RenderError.missingFunction("pass2_grain")
        }

        pass1Pipeline = try device.makeComputePipelineState(function: pass1)
        pass2Pipeline = try device.makeComputePipelineState(function: pass2)
    }

    private func loadGrainVolume() throws {
        // Folder references can land differently depending on Xcode version.
        // Enumerate the bundle to find grain3d.raw wherever it landed.
        let grainPath = findBundleFile(named: "grain3d.raw")
            ?? Bundle.main.path(forResource: "grain3d", ofType: "raw", inDirectory: "Grain")
            ?? Bundle.main.path(forResource: "grain3d", ofType: "raw")
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
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
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

    private func tempOutputURL() -> URL {
        // Use documents directory so output persists for viewing/sharing.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let name = "render_\(Int(Date().timeIntervalSince1970)).mov"
        return docs.appendingPathComponent(name)
    }
}

// MARK: - Supporting Types

struct GrainUniforms {
    var frameIndex: UInt
    var iso: Float
    var grainSize: Float
    var padding: Float = 0
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

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "Metal is not available on this device."
        case .noCommandQueue: return "Failed to create Metal command queue."
        case .noVideoTrack: return "Source video has no video track."
        case .readerFailed(let err): return "Asset reader failed: \(err?.localizedDescription ?? "unknown")"
        case .writerFailed(let err): return "Asset writer failed: \(err?.localizedDescription ?? "unknown")"
        case .missingShader(let name): return "Missing shader: \(name)"
        case .missingFunction(let name): return "Missing Metal function: \(name)"
        case .missingResource(let name): return "Missing resource: \(name)"
        case .invalidGrainData: return "Grain volume data is invalid or truncated."
        case .invalidLUTData: return "Failed to parse .cube LUT file."
        case .textureCreationFailed: return "Failed to create Metal texture."
        case .textureCacheCreationFailed: return "Failed to create Metal texture cache."
        }
    }
}