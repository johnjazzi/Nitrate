import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The receipt is the queue's only private evidence of what a delivered file
/// says. A still carries its payload in EXIF UserComment, so the photo branch
/// must read it back under the same namespaced keys as a movie receipt.
struct RenderReceiptPhotoMetadataTests {
    private final class BundleToken {}

    // MARK: - Fixtures

    /// Write a real JPEG the way the delivery pipeline does, so assertions run
    /// against bytes ImageIO actually produced rather than a moked dictionary.
    private func writeJPEG(at url: URL, comment: String?,
                           size: CGSize = CGSize(width: 40, height: 60)) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let comment {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: comment
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(sink))
    }

    private func temporaryJPEG(_ name: String = "receipt") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).jpg")
    }

    private func config(gauge: PrintGauge? = .thirtyFiveMillimetre) throws -> FilmStockConfig {
        let stock = FilmStockConfig(stockId: "test", displayName: "Kodak 5219", category: .video,
            lutName: "test.cube", halationStrength: 0, glowStrength: 0, grainSize: 1, defaultISO: 600)
        return stock.overridingGauge(gauge)
    }

    private func writeDeliveredStill(at url: URL, config: FilmStockConfig) throws {
        let size = CGSize(width: 64, height: 96)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        for (key, value) in try PhotoDeliveryMetadata.properties(
            config: config, capture: .init(exposureSeconds: 1.0 / 500.0, iso: 800),
            deliveredSize: size) {
            properties[key] = value
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(sink))
    }

    // MARK: - Capture reads the still payload

    @Test func captureReadsTheDeliveredStillsPayloadUnderMovieKeys() async throws {
        let url = temporaryJPEG("delivered")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeDeliveredStill(at: url, config: try config())

        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: nil,
                                                         includeThumbnail: false)

        #expect(receipt.metadata["com.filmemulation.film-stock"] == "test")
        #expect(receipt.metadata["com.filmemulation.stock-name"] == "Kodak 5219")
        #expect(receipt.metadata["com.filmemulation.print-gauge"] == PrintGauge.thirtyFiveMillimetre.rawValue)
        #expect(receipt.metadata["com.filmemulation.encoding-codec"] == "jpeg")
        #expect(receipt.metadata["com.filmemulation.iso"] == "800")
        #expect(receipt.metadata["com.filmemulation.shutter-speed"] == "1/500")
        // A still states no take-only claims.
        #expect(receipt.metadata["com.filmemulation.shutter-angle"] == nil)
        #expect(receipt.metadata["com.filmemulation.capture-frame-rate"] == nil)
        #expect(receipt.pixelWidth == 64)
        #expect(receipt.pixelHeight == 96)
        #expect(receipt.codec == UTType.jpeg.identifier)
    }

    /// The payload keys are written unprefixed; the receipt publishes them with
    /// the movie's `com.filmemulation.` namespace so the queue UI reads one
    /// shape for both media types.
    @Test func captureNeverPublishesAnUnprefixedKey() async throws {
        let url = temporaryJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJPEG(at: url, comment: #"{"film-stock":"test"}"#)

        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: nil,
                                                         includeThumbnail: false)

        #expect(receipt.metadata == ["com.filmemulation.film-stock": "test"])
    }

    // MARK: - Missing, malformed and unsupported payloads

    @Test(arguments: [
        nil,
        "",
        "   ",
        "not json",
        "{\"film-stock\":",
        "[1, 2, 3]",
        #"[{"film-stock":"test"}]"#,
        "{\"film-stock\": 42}"
    ] as [String?])
    func captureYieldsNoMetadataForMissingOrMalformedPayloads(comment: String?) async throws {
        let url = temporaryJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJPEG(at: url, comment: comment)

        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: nil,
                                                         includeThumbnail: false)

        #expect(receipt.metadata.isEmpty)
        // The receipt still records what the file itself proves.
        #expect(receipt.pixelWidth == 40)
        #expect(receipt.pixelHeight == 60)
    }

    @Test func captureDropsKeysOutsideTheAllowedPolicy() async throws {
        let url = temporaryJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJPEG(at: url, comment: """
        {"film-stock":"test","stock-name":"Kodak 5219","fstop":"2.8",
         "exposure-bias":"+1","camera-model":"Unsupported","gps-latitude":"51.5"}
        """)

        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: nil,
                                                         includeThumbnail: false)

        #expect(receipt.metadata == [
            "com.filmemulation.film-stock": "test",
            "com.filmemulation.stock-name": "Kodak 5219"
        ])
    }

    @Test func captureDropsAnOversizedValueButKeepsItsAllowedNeighbour() async throws {
        let url = temporaryJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let oversized = String(repeating: "a", count: 16_385)
        try writeJPEG(at: url, comment: #"{"film-stock":"test","stock-name":"\#(oversized)"}"#)

        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: nil,
                                                         includeThumbnail: false)

        #expect(receipt.metadata == ["com.filmemulation.film-stock": "test"])
    }
}

/// A photo receipt persisted before the image branch read the payload keeps an
/// empty metadata map even though the retained JPEG still states the recipe.
/// The queue may re-read that app-owned output; it must never consult Photos or
/// invent a value.
@MainActor
@Suite("Photo receipt metadata backfill")
struct RenderQueuePhotoReceiptBackfillTests {
    private enum Failure: Error { case denied }

    private func temporaryFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func writeJPEG(at url: URL, comment: String?) throws {
        let size = CGSize(width: 32, height: 48)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let comment {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: comment
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(sink))
    }

    private func photoJob(source: URL, output: URL, metadata: [String: String] = [:],
                          status: RenderJob.JobStatus = .completed) -> RenderJob {
        var job = RenderJob(sourceURL: source, stockId: "test", iso: 800)
        job.isPhoto = true
        job.photoCropZoom = 1
        job.photoGrainSeed = 1
        job.status = status
        job.outputURL = output
        job.outputSavedToPhotos = true
        job.receipt = RenderReceipt(renderDurationSeconds: 0.4,
                                    thumbnailJPEG: Data([0xFF, 0xD8]),
                                    metadata: metadata, appVersion: "1.0", appBuild: "1")
        return job
    }

    @Test func legacyPhotoReceiptGainsTheRetainedStillsMetadata() throws {
        let source = try temporaryFile("source.dng")
        let output = try temporaryFile("output.jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try writeJPEG(at: output, comment: #"{"film-stock":"test","stock-name":"Kodak 5219","fstop":"2.8"}"#)
        let persisted = [photoJob(source: source, output: output)]
        var durable: [RenderJob] = []
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
                                         postDelivery: nil, persist: { durable = $0 },
                                         load: { persisted })

        queue.onAppear()

        let receipt = try #require(queue.jobs.first?.receipt)
        #expect(receipt.metadata == [
            "com.filmemulation.film-stock": "test",
            "com.filmemulation.stock-name": "Kodak 5219"
        ])
        // Only the metadata gap is filled; the recorded evidence is untouched.
        #expect(receipt.appVersion == "1.0")
        #expect(receipt.appBuild == "1")
        #expect(receipt.renderDurationSeconds == 0.4)
        #expect(receipt.thumbnailJPEG == Data([0xFF, 0xD8]))
        #expect(durable.first?.receipt?.metadata == receipt.metadata)
    }

    @Test func photoReceiptWithoutARetainedOutputStaysEmpty() throws {
        let source = try temporaryFile("source.dng")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let persisted = [photoJob(source: source, output: missing)]
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
                                         postDelivery: nil, persist: { _ in },
                                         load: { persisted })

        queue.onAppear()

        // No local evidence means no claim: the receipt keeps an empty map.
        #expect(queue.jobs.first?.receipt?.metadata.isEmpty == true)
    }

    @Test func videoReceiptsAreNotBackfilled() throws {
        let source = try temporaryFile("clip.mov")
        let output = try temporaryFile("render.jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try writeJPEG(at: output, comment: #"{"film-stock":"test"}"#)
        var job = photoJob(source: source, output: output)
        job.isPhoto = nil
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
                                         postDelivery: nil, persist: { _ in },
                                         load: { [job] })

        queue.onAppear()

        #expect(queue.jobs.first?.receipt?.metadata.isEmpty == true)
    }

    @Test func anExistingMetadataMapIsNeverRewritten() throws {
        let source = try temporaryFile("source.dng")
        let output = try temporaryFile("output.jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try writeJPEG(at: output, comment: #"{"film-stock":"other"}"#)
        let existing = ["com.filmemulation.film-stock": "recorded"]
        let persisted = [photoJob(source: source, output: output, metadata: existing)]
        var writes = 0
        let queue = RenderQueueViewModel(render: { _ in throw Failure.denied }, save: { _ in },
                                         postDelivery: nil, persist: { _ in writes += 1 },
                                         load: { persisted })

        queue.onAppear()

        #expect(queue.jobs.first?.receipt?.metadata == existing)
        #expect(writes == 0)
    }
}
