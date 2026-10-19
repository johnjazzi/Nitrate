import Foundation
import Testing
import AVFoundation
import CoreGraphics

/// The consumer-visible tag: the short caption Photos shows and its keywords.
/// The verbose recipe stays in the `com.filmemulation.*` keys.
struct RenderConsumerMetadataTests {
    private let sensorSize = CGSize(width: 3840, height: 2160)
    /// Encoded frame for the written fixtures: non-square, so a delivery
    /// transform changes the displayed shape.
    private let encodedSize = (width: 128, height: 64)

    private func config(gauge: PrintGauge?) throws -> FilmStockConfig {
        let stock = FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
            lutName: "test.cube", halationStrength: 0, glowStrength: 0, grainSize: 1, defaultISO: 600)
        return stock.overridingGauge(gauge)
    }

    @Test func orientationFollowsTheDeliveredFrame() {
        #expect(RenderDeliveryOrientation.from(naturalSize: sensorSize, preferredTransform: .identity) == .landscape)
        // 180°: still wider than tall.
        #expect(RenderDeliveryOrientation.from(naturalSize: sensorSize,
            preferredTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: sensorSize.width, ty: sensorSize.height))
            == .landscape)
        // Both 90° holds are portrait: the delivered transform decides, not the sensor shape.
        #expect(RenderDeliveryOrientation.from(naturalSize: sensorSize,
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: sensorSize.height, ty: 0)) == .portrait)
        #expect(RenderDeliveryOrientation.from(naturalSize: sensorSize,
            preferredTransform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sensorSize.width)) == .portrait)
        // Square: no orientation is invented.
        #expect(RenderDeliveryOrientation.from(naturalSize: CGSize(width: 1080, height: 1080),
            preferredTransform: .identity) == nil)
    }

    @Test func keywordsNameNitrateAndTheCapturedOrientation() {
        #expect(RenderConsumerMetadata.keywords(orientation: .portrait) == ["nitrate", "portrait"])
        #expect(RenderConsumerMetadata.keywords(orientation: .landscape) == ["nitrate", "landscape"])
        #expect(RenderConsumerMetadata.keywords(orientation: nil) == ["nitrate"])
    }

    @Test func captionIsStockNameAndGaugeOnly() {
        #expect(RenderConsumerMetadata.caption(stockName: "Kodak 5219", gauge: "35mm") == "nitrate: Kodak 5219 | 35mm")
    }

    @Test func metadataItemsCarryTheCaptionAndKeywords() throws {
        let config = try config(gauge: .sixteenMillimetre)
        let items = try RenderMovieMetadata.make(config: config, orientation: .portrait)
        let caption = "nitrate: Kodak 5219 | 16mm"
        let title = try #require(items.first { $0.commonKey == .commonKeyTitle })
        let description = try #require(items.first { $0.commonKey == .commonKeyDescription })
        #expect(title.value as? String == caption)
        #expect(description.value as? String == caption)
        let keywords = try #require(items.first { ($0.key as? String) == AVMetadataKey.quickTimeMetadataKeyKeywords.rawValue })
        #expect(keywords.keySpace == .quickTimeMetadata)
        #expect(keywords.value as? String == "nitrate, portrait")
        // The detailed diagnostics are untouched by the shorter consumer tag.
        #expect(items.first { ($0.key as? String) == "com.filmemulation.iso" }?.value as? String == "600")
        #expect(items.first { ($0.key as? String) == "com.filmemulation.halation-level" }?.value as? String == "0.0")
    }

    @Test func deliveredMovieRoundTripsTheConsumerTag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: sensorSize.height, ty: 0)
        let portraitURL = directory.appendingPathComponent("portrait.mov")
        try await writeMovie(portraitURL, config: try config(gauge: .thirtyFiveMillimetre),
                             transform: portraitTransform, orientation: .portrait)
        let portraitTag = try #require(await RenderConsumerMetadata.tag(for: portraitURL))
        #expect(portraitTag.caption == "nitrate: Kodak 5219 | 35mm")
        #expect(portraitTag.keywords == ["nitrate", "portrait"])
        #expect(try await embeddedKeywords(portraitURL) == "nitrate, portrait")

        let landscapeURL = directory.appendingPathComponent("landscape.mov")
        try await writeMovie(landscapeURL, config: try config(gauge: .eightMillimetre),
                             transform: .identity, orientation: .landscape)
        let landscapeTag = try #require(await RenderConsumerMetadata.tag(for: landscapeURL))
        #expect(landscapeTag.caption == "nitrate: Kodak 5219 | 8mm")
        #expect(landscapeTag.keywords == ["nitrate", "landscape"])
        #expect(try await embeddedKeywords(landscapeURL) == "nitrate, landscape")
    }

    @Test func movieWithoutNitrateMetadataHasNoConsumerTag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plain.mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = silentVideoInput()
        writer.add(input)
        try appendSingleFrame(writer: writer, input: input, transform: .identity)
        #expect(await RenderConsumerMetadata.tag(for: url) == nil)
    }

    // MARK: - Helpers

    private func embeddedKeywords(_ url: URL) async throws -> String? {
        for item in try await AVURLAsset(url: url).load(.metadata)
        where (item.key as? String) == AVMetadataKey.quickTimeMetadataKeyKeywords.rawValue {
            return try await item.load(.stringValue)
        }
        return nil
    }

    private func silentVideoInput() -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: encodedSize.width,
            AVVideoHeightKey: encodedSize.height
        ])
    }

    private func appendSingleFrame(writer: AVAssetWriter, input: AVAssetWriterInput,
                                   transform: CGAffineTransform) throws {
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, encodedSize.width, encodedSize.height,
                                    kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()
    }

    private func writeMovie(_ url: URL, config: FilmStockConfig,
                            transform: CGAffineTransform, orientation: RenderDeliveryOrientation) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = silentVideoInput()
        writer.add(input)
        writer.metadata = try RenderMovieMetadata.make(config: config, orientation: orientation)
        try appendSingleFrame(writer: writer, input: input, transform: transform)
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
