import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing
import simd

/// The development white balance on the GPU: the real kernel, real textures and
/// the real delivered render. These are the numbers a preview and a delivery are
/// made of, not a re-derivation of the matrix in the test.
@Suite(.serialized)
struct DevelopWhiteBalanceRenderTests {
    private final class BundleToken { }
    private var bundle: Bundle { Bundle(for: BundleToken.self) }

    private enum FixtureError: Error {
        case metal
        case texture
        case dispatch
        case buffer
        case writer(String?)
        case read
        case pixels
    }

    // MARK: - The shipping kernel on real textures

    /// Zero warmth must hand back the INPUT TEXTURE ITSELF. Not an equal copy: a
    /// neutral job may not allocate or dispatch at all, which is what keeps the
    /// default path's bytes and cost unchanged.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
    func zeroWarmthHandsBackTheInputTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try DevelopWhiteBalanceStage(device: device, library: try library(device))
        let input = try texture(device, codes: [SIMD3<Float>(repeating: 0.5)])

        for warmth: Float in [0, -0, .nan] {
            let output = try stage.corrected(input, referenceKelvin: 5_600, warmth: warmth,
                                             commandQueue: queue)
            // Keep the existential identity comparison out of #expect's generic
            // operator expansion: Cloud's Swift 6.4.0 aborts while lowering it.
            let isInputTexture = (output as AnyObject) === (input as AnyObject)
            #expect(isInputTexture,
                    "warmth \(warmth) must bypass the correction entirely")
        }
    }

    /// Direction and magnitude, measured on the numbers the kernel wrote: a warm
    /// correction raises red above blue on a neutral plate, a cool one does the
    /// opposite, and both move the code off its input.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
    func warmAndCoolMoveNeutralCodesInOppositeDirections() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try DevelopWhiteBalanceStage(device: device, library: try library(device))
        let neutral = try log2Codes(linearSRGB: SIMD3(repeating: 0.18))
        let input = try texture(device, codes: Array(repeating: neutral, count: 4))

        let white = try readCodes(try stage.corrected(input, referenceKelvin: 5_600, warmth: 0,
                                                     commandQueue: queue),
                                  device: device, queue: queue)
        let warm = try readCodes(try stage.corrected(input, referenceKelvin: 5_600, warmth: 0.8,
                                                     commandQueue: queue),
                                 device: device, queue: queue)
        let cool = try readCodes(try stage.corrected(input, referenceKelvin: 5_600, warmth: -0.8,
                                                     commandQueue: queue),
                                 device: device, queue: queue)

        for index in white.indices {
            #expect(abs(white[index].x - neutral.x) < 2e-4, "zero warmth must not move a code")
            #expect(abs(white[index].y - neutral.y) < 2e-4)
            #expect(abs(white[index].z - neutral.z) < 2e-4)
        }
        for index in warm.indices {
            #expect(warm[index].x > warm[index].z,
                    "a warm correction must raise red above blue, got \(warm[index])")
            #expect(abs(warm[index].x - cool[index].x) > 1e-3)
            #expect(abs(warm[index].z - cool[index].z) > 1e-3)
        }
        for index in cool.indices {
            #expect(cool[index].z > cool[index].x,
                    "a cool correction must raise blue above red, got \(cool[index])")
        }
        // The render is deterministic: every texel of one flat plate agrees.
        #expect(warm.dropFirst().allSatisfy { $0 == warm[0] })
    }

    /// Shadows and speculars stay finite at both ends of the control, and the
    /// tone order is preserved: a bright plate is still brighter than a dark one
    /// after the white moves.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
    func highlightsAndShadowsStayFiniteAndOrdered() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try DevelopWhiteBalanceStage(device: device, library: try library(device))
        // Black, deep shadow, mid grey, diffuse white, a clipped specular.
        let input = try texture(device, codes: try [0.0, 0.001, 0.18, 1.0, 4.0].map {
            try log2Codes(linearSRGB: SIMD3(repeating: $0))
        })

        for warmth: Float in [-1, -0.5, 0.5, 1] {
            let codes = try readCodes(try stage.corrected(input, referenceKelvin: 5_600, warmth: warmth,
                                                          commandQueue: queue),
                                      device: device, queue: queue)
            for code in codes {
                for channel in [code.x, code.y, code.z] {
                    #expect(channel.isFinite, "warmth \(warmth) produced a non-finite code")
                    #expect(channel >= -0.0002, "the Apple Log 2 encode cannot go below its toe")
                    #expect(channel < 1.05, "a clipped specular must stay on the Log 2 chart")
                }
            }
            // Order is preserved across the whole range.
            for index in 1..<codes.count {
                #expect(codes[index].y > codes[index - 1].y,
                        "warmth \(warmth) inverted the tone order at index \(index)")
            }
        }
    }

    /// The correction changes colour, not exposure: the plate's neutral keeps its
    /// luminance (the adaptation is normalized), so a white-balanced frame does
    /// not also get brighter or darker.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
    func neutralLuminanceSurvivesTheAdaptation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let stage = try DevelopWhiteBalanceStage(device: device, library: try library(device))
        let levels: [Double] = [0.05, 0.18, 1.0]
        let input = try texture(device, codes: try levels.map {
            try log2Codes(linearSRGB: SIMD3(repeating: $0))
        })
        let luma = try appleWideGamutLuma()

        for warmth: Float in [-1, 1] {
            let codes = try readCodes(try stage.corrected(input, referenceKelvin: 3_200, warmth: warmth,
                                                          commandQueue: queue),
                                      device: device, queue: queue)
            for (index, level) in levels.enumerated() {
                let linear = SIMD3(Float(PhotoColorMath.appleLog2Decode(Double(codes[index].x))),
                                   Float(PhotoColorMath.appleLog2Decode(Double(codes[index].y))),
                                   Float(PhotoColorMath.appleLog2Decode(Double(codes[index].z))))
                let corrected = simd_dot(luma, linear)
                #expect(abs(corrected - Float(level)) < max(0.002, Float(level) * 0.01),
                        "warmth \(warmth) moved luminance \(level) to \(corrected)")
            }
        }
    }

    // MARK: - One implementation for preview and delivery

    /// The frame preview and the delivered render must dispatch the SAME
    /// correction. The preview's resources own a stage; a separately built stage
    /// is what `PipelineRenderer` holds; their codes must agree exactly.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
    func previewAndExportDispatchTheSameCorrection() throws {
        let color = try DevelopColorPreviewResources(bundle: bundle)
        let stage = try DevelopWhiteBalanceStage(device: color.device, library: try library(color.device))
        let buffer = try logBuffer()
        let prepared = try color.prepare(buffer)

        for warmth: Float in [-0.75, -0.2, 0.2, 0.75] {
            let balance = DevelopWhiteBalance(videoWarmth: warmth)
            let preview = try color.corrected(prepared, whiteBalance: balance,
                                              referenceKelvin: 3_200)
            let delivered = try stage.corrected(prepared, referenceKelvin: 3_200,
                                                warmth: balance.resolvedVideoWarmth,
                                                commandQueue: color.queue)
            #expect(preview.storageMode == .shared, "The preview exposure curve may read corrected codes on the CPU")
            let previewCodes = try readCodes(preview, device: color.device, queue: color.queue)
            let deliveredCodes = try readCodes(delivered, device: color.device, queue: color.queue)
            #expect(previewCodes.count == deliveredCodes.count)
            for index in previewCodes.indices {
                for channel in 0..<3 {
                    let difference = abs(previewCodes[index][channel] - deliveredCodes[index][channel])
                    #expect(difference < 1e-4,
                            "preview and export disagreed by \(difference) at texel \(index)")
                }
            }
        }

        // And a neutral job is a pure pass-through on the preview side too.
        let neutral = try color.corrected(prepared, whiteBalance: .neutral, referenceKelvin: 3_200)
        let isPreparedTexture = (neutral as AnyObject) === (prepared as AnyObject)
        #expect(isPreparedTexture)
    }

    /// End to end through the preview entry point: a neutral preview is byte-for-
    /// byte the preview this app always produced, and warmth moves the picture in
    /// the direction the control says.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func previewIsUnchangedWhenNeutralAndMovesWhenWarmed() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let neutral = try await renderVideo(renderer, buffer: try logBuffer(), stock: config,
                                            whiteBalance: .neutral)
        let zero = try await renderVideo(renderer, buffer: try logBuffer(), stock: config,
                                         whiteBalance: DevelopWhiteBalance(videoWarmth: 0))
        #expect(try pixels(neutral.image) == pixels(zero.image),
                "an explicit zero warmth must render exactly the neutral preview")

        let warm = try await renderVideo(renderer, buffer: try logBuffer(), stock: config,
                                         whiteBalance: DevelopWhiteBalance(videoWarmth: 0.9))
        let cool = try await renderVideo(renderer, buffer: try logBuffer(), stock: config,
                                         whiteBalance: DevelopWhiteBalance(videoWarmth: -0.9))
        #expect(try pixels(warm.image) != pixels(neutral.image),
                "a warm development must change the preview")
        #expect(try pixels(cool.image) != pixels(neutral.image),
                "a cool development must change the preview")
        #expect(try redness(warm.image) > redness(cool.image),
                "the warm preview must be warmer than the cool one after the same grade")
        // The meter is the file's own as-shot reading and never consumes the
        // development grade.
        #expect(warm.measuredOffsetEV == neutral.measuredOffsetEV)
        #expect(cool.measuredOffsetEV == neutral.measuredOffsetEV)
    }

    // MARK: - The real queue path

    /// The delivered movie: the queue entry point applies the warmth before the
    /// halo and the LUT, and the file states the relative value it applied while
    /// leaving the capture lock alone.
    @Test(.timeLimit(.minutes(1)))
    func deliveredMovieAppliesTheWarmthAndStatesIt() async throws {
        try #require(MTLCreateSystemDefaultDevice() != nil, "Requires Metal")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await writeGrayMovie(at: source)

        let renderer = try PipelineRenderer(resourceBundle: bundle, outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let config = try stock()
        let neutral = try await renderer.render(sourceURL: source, config: config,
                                                bitrate: 2_000_000, whiteBalance: .neutral)
        let warm = try await renderer.render(sourceURL: source, config: config, bitrate: 2_000_000,
                                             whiteBalance: DevelopWhiteBalance(videoWarmth: 1))
        let cool = try await renderer.render(sourceURL: source, config: config, bitrate: 2_000_000,
                                             whiteBalance: DevelopWhiteBalance(videoWarmth: -1))
        defer {
            for url in [neutral, warm, cool] { try? FileManager.default.removeItem(at: url) }
        }

        let neutralRedness = try await redness(ofFirstTakeFrameAt: neutral)
        let warmRedness = try await redness(ofFirstTakeFrameAt: warm)
        let coolRedness = try await redness(ofFirstTakeFrameAt: cool)
        #expect(warmRedness > coolRedness,
                "the delivered warm take (\(warmRedness)) must be warmer than the cool one (\(coolRedness))")

        let warmValues = try await movieMetadata(warm)
        #expect(warmValues["development-video-warmth"] == "1.000")
        let receipt = await RenderReceiptService.capture(url: warm, renderDurationSeconds: nil,
                                                         includeThumbnail: false)
        #expect(receipt.metadata["com.filmemulation.development-video-warmth"] == "1.000")
        #expect(warmValues["white-balance-kelvin"] == String(Int(config.colorTemperature)),
                "the capture lock must not be rewritten by a development white balance")
        let coolValues = try await movieMetadata(cool)
        #expect(coolValues["development-video-warmth"] == "-1.000")
        let neutralValues = try await movieMetadata(neutral)
        #expect(neutralValues["development-video-warmth"] == nil,
                "a neutral delivery states no development white balance")
        #expect(neutralValues["white-balance-kelvin"] == String(Int(config.colorTemperature)))
        // The neutral delivery is still the shipping recipe.
        #expect(neutralRedness != warmRedness)
    }

    // MARK: - Fixtures

    private func library(_ device: any MTLDevice) throws -> MTLLibrary {
        try device.makeDefaultLibrary(bundle: bundle)
    }

    private func texture(_ device: any MTLDevice, codes: [SIMD3<Float>]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: codes.count, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw FixtureError.texture }
        var words: [Float16] = []
        words.reserveCapacity(codes.count * 4)
        for code in codes {
            words.append(Float16(code.x))
            words.append(Float16(code.y))
            words.append(Float16(code.z))
            words.append(1)
        }
        words.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, codes.count, 1), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: codes.count * 8)
        }
        return texture
    }

    /// Blit the result into a shared texture so a `.private` stage output can be
    /// read back through the same lifetime rules the pipeline uses.
    private func readCodes(_ texture: MTLTexture, device: any MTLDevice,
                           queue: MTLCommandQueue) throws -> [SIMD3<Float>] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: texture.width, height: texture.height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let shared = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { throw FixtureError.texture }
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw FixtureError.dispatch }

        var words = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        words.withUnsafeMutableBytes { bytes in
            shared.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8,
                            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                            mipmapLevel: 0)
        }
        return (0..<(texture.width * texture.height)).map { index in
            SIMD3<Float>(Float(words[index * 4]), Float(words[index * 4 + 1]),
                         Float(words[index * 4 + 2]))
        }
    }

    private func log2Codes(linearSRGB: SIMD3<Double>) throws -> SIMD3<Float> {
        let result = try PhotoColorMath.transform(linearSRGB: linearSRGB)
        return SIMD3<Float>(Float(result.appleLog2.x), Float(result.appleLog2.y),
                            Float(result.appleLog2.z))
    }

    /// Apple Wide Gamut's luminance row, derived the way the plate transform is:
    /// the primaries map their D65 white to Y = 1.
    private func appleWideGamutLuma() throws -> SIMD3<Float> {
        func toXYZ(_ chromaticity: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(chromaticity.x / chromaticity.y, 1,
                  (1 - chromaticity.x - chromaticity.y) / chromaticity.y)
        }
        let primaries = simd_float3x3(toXYZ(SIMD2(0.725, 0.301)), toXYZ(SIMD2(0.221, 0.814)),
                                      toXYZ(SIMD2(0.068, -0.076)))
        let matrix = primaries * simd_float3x3(diagonal: primaries.inverse * toXYZ(SIMD2(0.3127, 0.3290)))
        let luma = SIMD3<Float>(matrix[0][1], matrix[1][1], matrix[2][1])
        #expect(abs(luma.x + luma.y + luma.z - 1) < 1e-3)
        return luma
    }

    /// A tagged Apple Log 2 frame: a flat neutral plate, so any colour in the
    /// result came from the development white balance.
    private func logBuffer(width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf,
                                  attributes as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional else { throw FixtureError.buffer }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw FixtureError.buffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FixtureError.buffer }
        let codes = try log2Codes(linearSRGB: SIMD3(repeating: 0.18))
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
                .assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                row[x * 4] = Float16(codes.x)
                row[x * 4 + 1] = Float16(codes.y)
                row[x * 4 + 2] = Float16(codes.z)
                row[x * 4 + 3] = 1
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey,
                              kCVImageBufferLogTransferFunction_AppleLog2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private func stock(_ id: String = "kodak5219") throws -> FilmStockConfig {
        struct Catalog: Decodable { let stocks: [FilmStockConfig] }
        let url = bundle.url(forResource: "stocks", withExtension: "json")
            ?? TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return try #require(catalog.stocks.first { $0.stockId == id })
    }

    private func renderVideo(_ renderer: DevelopFramePreviewRenderer, buffer: sending CVPixelBuffer,
                             stock: FilmStockConfig,
                             whiteBalance: DevelopWhiteBalance) async throws -> DevelopFramePreview {
        let measurement = DevelopFramePreviewRenderer.measureVideo(buffer)
        return try await renderer.renderVideo(buffer, stock: stock, gauge: .neutral, pushPull: .neutral,
                                              measurement: measurement,
                                              captureDescription: nil, whiteBalance: whiteBalance)
    }

    private func srgbBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw FixtureError.pixels }
        try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: image.width,
                                          height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw FixtureError.pixels
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Mean red minus mean blue: a positive number is a warmer picture.
    private func redness(_ image: CGImage) throws -> Double {
        let bytes = try srgbBytes(image)
        var red = 0.0, blue = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            red += Double(bytes[index])
            blue += Double(bytes[index + 2])
        }
        let count = Double(bytes.count / 4)
        return (red - blue) / count
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        try srgbBytes(image)
    }

    /// A tiny grey movie: one flat neutral frame repeated, encoded as ordinary
    /// SDR video. It is not a colour claim, only a source the renderer will take.
    private func writeGrayMovie(at url: URL, frames: Int = 8, size: Int = 64) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else { throw FixtureError.writer(nil) }
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.writer(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError.buffer }
        let deadline = Date().addingTimeInterval(10)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.isReadyForMoreMediaData else {
                throw FixtureError.writer(writer.error?.localizedDescription)
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess,
                  let buffer = optional else { throw FixtureError.buffer }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw FixtureError.buffer }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<size {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<size {
                        // BGRA: a mid grey plate with no colour of its own.
                        row[x * 4] = 128
                        row[x * 4 + 1] = 128
                        row[x * 4 + 2] = 128
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                throw FixtureError.writer(writer.error?.localizedDescription)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 10))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.writer(writer.error?.localizedDescription)
        }
    }

    /// Redness of the take's own frame: the same film ramp may write black leader
    /// frames first, so the brightest frame (the grey take) is the one measured.
    private func redness(ofFirstTakeFrameAt url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { throw FixtureError.read }
        reader.add(output)
        guard reader.startReading() else { throw FixtureError.read }
        var best: (redness: Double, luma: Double)?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { continue }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { continue }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            var red = 0.0, blue = 0.0, luma = 0.0
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let b = Double(row[x * 4]), g = Double(row[x * 4 + 1]), r = Double(row[x * 4 + 2])
                    red += r
                    blue += b
                    luma += (r + g + b) / 3
                }
            }
            let count = Double(width * height)
            let frame = (redness: (red - blue) / count, luma: luma / count)
            if best == nil || frame.luma > best!.luma { best = frame }
        }
        guard let best else { throw FixtureError.read }
        return best.redness
    }

    private func movieMetadata(_ url: URL) async throws -> [String: String] {
        var values: [String: String] = [:]
        for item in try await AVURLAsset(url: url).load(.metadata) {
            guard let key = item.key as? String, key.hasPrefix("com.filmemulation."),
                  let value = try await item.load(.stringValue) else { continue }
            values[String(key.dropFirst("com.filmemulation.".count))] = value
        }
        return values
    }
}
