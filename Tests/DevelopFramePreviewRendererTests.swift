import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing

@Suite(.serialized)
struct DevelopFramePreviewRendererTests {
    private final class BundleToken {}
    private var bundle: Bundle { Bundle(for: BundleToken.self) }

    private func stock(_ id: String = "kodak5219") throws -> FilmStockConfig {
        struct Catalog: Decodable { let stocks: [FilmStockConfig] }
        let url = bundle.url(forResource: "stocks", withExtension: "json")
            ?? TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        return try #require(JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).stocks.first { $0.stockId == id })
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func mean(_ image: CGImage) throws -> Double {
        let bytes = try pixels(image)
        return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) {
            $0 + (Double(bytes[$1]) + Double(bytes[$1 + 1]) + Double(bytes[$1 + 2])) / 3
        } / Double(image.width * image.height)
    }

    private func assertSpatialRange(_ image: CGImage) throws {
        let bytes = try pixels(image)
        let red = stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
        #expect(red.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect((red.max() ?? 0) - (red.min() ?? 0) > 0.12, "A real gradient must survive; nonblank uniform output is not sufficient")
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func numericalFilmOutputIsFiniteAndRetainsSpatialDynamicRange() throws {
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .neutral, seed: 0, bundle: bundle)
        let image = DevelopPreviewFixtures.linearImage()
        let finished = try DevelopmentPhotoRenderer.develop(linearImage: image, film: film,
                                                            sceneLiftStops: 1, halationHeadroom: 1)
        var values = [Float](repeating: 0, count: 128 * 80 * 4)
        film.context.render(finished, toBitmap: &values, rowBytes: 128 * 16, bounds: image.extent,
                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let channels = values.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        #expect(channels.allSatisfy { $0.isFinite })
        #expect((channels.max() ?? 0) - (channels.min() ?? 0) > 0.12)
        #expect((channels.min() ?? -1) >= 0)
        #expect((channels.max() ?? 2) <= 1.01)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func photoUsesRealSpatialFilmStagesAndPushPullDoesNotRewriteMeter() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let neutral = try await renderer.gradientPhoto(config, pushPull: .neutral)
        let pull = try await renderer.gradientPhoto(config, pushPull: .manual(.pullOne))
        let push = try await renderer.gradientPhoto(config, pushPull: .manual(.pushOne))
        for result in [neutral, pull, push] {
            #expect(result.image.width == 128 && result.image.height == 80)
            try assertSpatialRange(result.image)
            #expect(result.captureDescription == nil)
            #expect(result.measuredOffsetEV == neutral.measuredOffsetEV)
        }
        #expect(try mean(pull.image) < mean(neutral.image))
        #expect(try mean(push.image) > mean(neutral.image))
        #expect(neutral.measuredOffsetEV != nil)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func photoGaugeAndStockChangesGradePixelsWithoutChangingSourceExposure() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let fine = try await renderer.gradientPhoto(config, gauge: .seventyFiveMillimetre)
        for gauge in PrintGauge.allCases {
            let result = try await renderer.gradientPhoto(config, gauge: gauge)
            try assertSpatialRange(result.image)
            #expect(result.measuredOffsetEV == fine.measuredOffsetEV)
            if gauge != .seventyFiveMillimetre { #expect(try pixels(result.image) != pixels(fine.image)) }
        }
        let other = try await renderer.gradientPhoto(stock("kodakektachrome100d"), gauge: .seventyFiveMillimetre)
        #expect(try pixels(other.image) != pixels(fine.image))
        #expect(other.measuredOffsetEV == fine.measuredOffsetEV)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func videoUsesLogProvenanceAndActualPipelineWithFrameSpecificCeiling() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let neutral = try await renderer.gradientVideo(config)
        let pull = try await renderer.gradientVideo(config, pushPull: .manual(.pullOne))
        let push = try await renderer.gradientVideo(config, pushPull: .manual(.pushOne))
        for result in [neutral, pull, push] { try assertSpatialRange(result.image) }
        #expect(try mean(pull.image) < mean(neutral.image))
        #expect(try mean(push.image) > mean(neutral.image))
        #expect(pull.measuredOffsetEV == neutral.measuredOffsetEV)
        #expect(push.measuredOffsetEV == neutral.measuredOffsetEV)
        #expect(neutral.captureDescription == nil)
        let coarse = try await renderer.gradientVideo(config, gauge: .eightMillimetre)
        #expect(try pixels(coarse.image) != pixels(neutral.image))
        #expect(coarse.measuredOffsetEV == neutral.measuredOffsetEV)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func retainedHLGVideoUsesProductionAdapterRatherThanPretendingItIsLog() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let result = try await renderer.gradientVideo(stock(), hlg: true)
        #expect(result.image.width == 128 && result.image.height == 80)
        #expect(try #require(result.measuredOffsetEV).isFinite)
        try assertSpatialRange(result.image)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal and bundled film resources"))
    func videoOrientationIsAppliedOnceAndPhotoDoesNotDoubleApplyEXIF() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let normal = try await renderer.gradientVideo(config)
        let rotated = try await renderer.gradientVideo(config, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0))
        #expect(rotated.image.width == normal.image.height)
        #expect(rotated.image.height == normal.image.width)
        #expect(rotated.measuredOffsetEV == normal.measuredOffsetEV)
        let expectedImage = CIImage(cgImage: normal.image).transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        let expected = try #require(CIContext().createCGImage(expectedImage, from: expectedImage.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let actualPixels = try pixels(rotated.image), expectedPixels = try pixels(expected)
        #expect(actualPixels.count == expectedPixels.count)
        let difference = zip(actualPixels, expectedPixels).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 255
        #expect(difference <= 2)
        // The decoded texture is already upright. The renderer has no EXIF
        // transform to reapply, including after a rectangular photo crop.
        let photo = try await renderer.gradientPhoto(config, cropZoom: 2)
        #expect(photo.image.width == 64 && photo.image.height == 40)
    }

    @Test func codeDomainResamplingIsBoundedAndKeepsProfileAndMeter() throws {
        let source = try DevelopPreviewFixtures.logBuffer(width: 1200, height: 800)
        let small = try DevelopFramePreviewRenderer.boundedBuffer(source)
        #expect(CVPixelBufferGetWidth(small) == 960)
        #expect(CVPixelBufferGetHeight(small) == 640)
        #expect(RenderInputColorProvenance.profile(of: small) == .appleLog2)
        let sourceEV = try #require(DevelopFramePreviewRenderer.measureVideo(source))
        let smallEV = try #require(DevelopFramePreviewRenderer.measureVideo(small))
        #expect(abs(sourceEV - smallEV) < 0.02)
        #expect(CVPixelBufferGetWidth(source) == 1200, "Resampling must not mutate the original")
        #expect(throws: DevelopFramePreviewRenderer.PreviewError.self) {
            try DevelopFramePreviewRenderer.boundedBuffer(source, cropZoom: .nan)
        }
    }

    @Test func untaggedStorageIsRefusedInsteadOfBeingTreatedAsLog() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        do {
            _ = try await renderer.untaggedVideo(stock())
            Issue.record("RGBA-half storage does not establish Log provenance")
        } catch let error as DevelopFramePreviewRenderer.PreviewError {
            guard case .unsupportedVideo = error else { Issue.record("Expected a source-profile refusal"); return }
        }
    }

    @Test func absentMetadataIsNotCurrentCameraISOOrAZeroExposure() {
        #expect(DevelopFramePreviewRenderer.captureDescription(.init()) == nil)
        #expect(DevelopFramePreviewRenderer.captureDescription(.init(exposureSeconds: .nan, iso: -1, fNumber: 0)) == nil)
        #expect(DevelopFramePreviewRenderer.captureDescription(.init(exposureSeconds: 0.01, iso: 640, fNumber: 2.8)) == "ISO 640 · 1/100 s · f/2.8")
        #expect(throws: DevelopFramePreviewRenderer.PreviewError.self) {
            try DevelopFramePreviewRenderer.sourceProfile([])
        }
    }

    @Test func cancellationAndMissingOriginalNeverReturnAPlaceholderPreview() async throws {
        let renderer = DevelopFramePreviewRenderer(bundle: bundle)
        let config = try stock()
        let missing = TestRepository.root.appendingPathComponent("absent-preview-original.dng")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await renderer.preview(url: missing, isPhoto: true, stock: config, gauge: .neutral, pushPull: .neutral)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await cancelled.value)
        do {
            _ = try await renderer.preview(url: missing, isPhoto: true, stock: config, gauge: .neutral, pushPull: .neutral)
            Issue.record("A missing original must not produce an image")
        } catch let error as DevelopFramePreviewRenderer.PreviewError {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}

/// Spatial fixtures run through the SAME internal methods as file-backed sources.
/// They test actual grading, not a synthetic replacement for failed file decode.
private enum DevelopPreviewFixtures {
    static func scene(x: Int, y: Int, width: Int, height: Int) -> SIMD3<Double> {
        let light = 0.02 + 0.48 * Double(x) / Double(max(1, width - 1))
        let vertical = 0.7 + 0.3 * Double(y) / Double(max(1, height - 1))
        return SIMD3(light, light * vertical, light * 0.8)
    }

    static func linearImage() -> CIImage {
        let width = 128, height = 80
        var values: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let rgb = scene(x: x, y: y, width: width, height: height)
                values += [Float(rgb.x), Float(rgb.y), Float(rgb.z), 1]
            }
        }
        return values.withUnsafeBytes { bytes in
            CIImage(bitmapData: Data(bytes), bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
    }

    static func logBuffer(width: Int = 128, height: Int = 80, tagged: Bool = true) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &optional) == kCVReturnSuccess)
        let buffer = try #require(optional)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                let codes = try PhotoColorMath.transform(linearSRGB: scene(x: x, y: y, width: width, height: height)).appleLog2
                for channel in 0..<3 { row[x * 4 + channel] = Float16(codes[channel]) }
                row[x * 4 + 3] = 1
            }
        }
        if tagged {
            CVBufferSetAttachment(buffer, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        return buffer
    }

    static func hlgBuffer() throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        #expect(CVPixelBufferCreate(nil, 128, 80, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                    attributes as CFDictionary, &optional) == kCVReturnSuccess)
        let buffer = try #require(optional)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for y in 0..<height {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    if plane == 0 { row[x] = UInt16(180 + 570 * x / (width - 1)) << 6 }
                    else { row[x * 2] = 512 << 6; row[x * 2 + 1] = 512 << 6 }
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }
}

fileprivate extension DevelopFramePreviewRenderer {
    func gradientPhoto(_ stock: FilmStockConfig, gauge: PrintGauge = .neutral,
                       pushPull: PushPullExposure = .neutral, cropZoom: Double = 1) throws -> DevelopFramePreview {
        let width = 128, height = 80
        var values: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let scene = DevelopPreviewFixtures.scene(x: x, y: y, width: width, height: height)
                values += [Float(scene.x), Float(scene.y), Float(scene.z), 1]
            }
        }
        let image = values.withUnsafeBytes { bytes in
            CIImage(bitmapData: Data(bytes), bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let decoder = try RAWPhotoDecoder(device: device, queue: queue)
        let texture = try decoder.renderLinearImage(image)
        let decoded = RAWPhotoDecoder.Decoded(texture: texture, linearImage: image,
            nativeSize: image.extent.size, orientedExtent: image.extent, settings: [:],
            baselineExposure: 0, metadata: nil, halationHeadroom: 1)
        return try renderPhoto(decoded, stock: stock, gauge: gauge, pushPull: pushPull, cropZoom: cropZoom,
                               measurement: Self.measurePhoto(image), captureDescription: nil)
    }

    func untaggedVideo(_ stock: FilmStockConfig) throws -> DevelopFramePreview {
        let buffer = try DevelopPreviewFixtures.logBuffer(tagged: false)
        return try renderVideo(buffer, stock: stock, gauge: .neutral, pushPull: .neutral,
                               measurement: nil, captureDescription: nil)
    }

    func gradientVideo(_ stock: FilmStockConfig, gauge: PrintGauge = .neutral,
                       pushPull: PushPullExposure = .neutral, transform: CGAffineTransform = .identity,
                       hlg: Bool = false) throws -> DevelopFramePreview {
        let buffer = try hlg ? DevelopPreviewFixtures.hlgBuffer() : DevelopPreviewFixtures.logBuffer()
        return try renderVideo(buffer, transform: transform, stock: stock, gauge: gauge, pushPull: pushPull,
                               measurement: Self.measureVideo(buffer), captureDescription: nil)
    }
}
