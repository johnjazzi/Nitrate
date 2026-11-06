import AVFoundation
import CoreVideo
import Foundation
import Testing

/// End-to-end proof that a 4:3 delivery is a real crop: a real render of a 16:9
/// source is written at the crop's own pixel size, its metadata states the
/// framing, the recorded original is untouched, and the frame's left edge holds
/// the centre of the source rather than the whole frame squeezed into fewer
/// columns.
@Suite(.serialized)
struct DeliveryFramingRenderTests {
    private final class BundleToken {}

    /// 160x90 is 16:9, so a 4:3 delivery of it is 120x90 — small enough to
    /// render in a test, exact under the policy's rounding rule.
    private static let sourceWidth = 160
    private static let sourceHeight = 90
    private static let deliveredWidth = 120

    /// Columns strictly outside the kept centre. The crop starts at x = 20, so
    /// these bands are the only content a squash would still show at the
    /// delivered left edge.
    private static let removedBandWidth = 16

    @Test func fourThreeDeliveryWritesTheCropSizeAndRecordsIt() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await Self.makeFixture(at: source)
        let sourceData = try Data(contentsOf: source)

        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self),
                                            outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let output = try await renderer.render(sourceURL: source, config: Self.loadConfig(),
                                               bitrate: 1_000_000, framing: .fourThree)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputAsset = AVURLAsset(url: output)
        let videoTrack = try #require(try await outputAsset.loadTracks(withMediaType: .video).first)
        let size = try await videoTrack.load(.naturalSize)
        #expect(size == CGSize(width: Self.deliveredWidth, height: Self.sourceHeight))

        // Small enough to read the whole first frame; no audio fixture needed.
        var metadata: [String: String] = [:]
        for item in try await outputAsset.load(.metadata) {
            if let key = item.key as? String, let value = try await item.load(.stringValue) {
                metadata[key] = value
            }
        }
        #expect(metadata["com.filmemulation.framing"] == "4:3")
        #expect(metadata["com.filmemulation.delivered-width"] == "\(Self.deliveredWidth)")
        #expect(metadata["com.filmemulation.delivered-height"] == "\(Self.sourceHeight)")
        // The delivered clip is portrait/landscape as encoded; the source's
        // rotation transform is preserved, so the keywords still describe it.
        #expect(metadata["com.filmemulation.encoding-codec"] == RenderEncodingContract.codec)

        // The original is never rewritten by a crop.
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test func sixteenNineDeliveryIsUnchanged() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await Self.makeFixture(at: source)

        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self),
                                            outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)
        let output = try await renderer.render(sourceURL: source, config: Self.loadConfig(),
                                               bitrate: 1_000_000)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputAsset = AVURLAsset(url: output)
        let videoTrack = try #require(try await outputAsset.loadTracks(withMediaType: .video).first)
        #expect(try await videoTrack.load(.naturalSize)
            == CGSize(width: Self.sourceWidth, height: Self.sourceHeight))
        var framing: String?
        for item in try await outputAsset.load(.metadata) where (item.key as? String) == "com.filmemulation.framing" {
            framing = try await item.load(.stringValue)
        }
        #expect(framing == "16:9")
    }

    /// A crop keeps the centre pixels; a squash would keep the removed edge
    /// bands. The delivered left edge is compared with the same position in an
    /// otherwise identical 16:9 render of the same source: it must match the
    /// *centre* content, not the edge band.
    @Test func fourThreeDeliveryCropsPixelsInsteadOfSqueezingThem() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await Self.makeFixture(at: source)
        let renderer = try PipelineRenderer(resourceBundle: Bundle(for: BundleToken.self),
                                            outputDirectory: directory,
                                            allowsSyntheticInputForTests: true)

        let wide = try await renderer.render(sourceURL: source, config: Self.loadConfig(),
                                             bitrate: 1_000_000)
        defer { try? FileManager.default.removeItem(at: wide) }
        let cropped = try await renderer.render(sourceURL: source, config: Self.loadConfig(),
                                                bitrate: 1_000_000, framing: .fourThree)
        defer { try? FileManager.default.removeItem(at: cropped) }

        let widePixels = try await Self.firstFrame(url: wide, width: Self.sourceWidth,
                                                   height: Self.sourceHeight)
        let croppedPixels = try await Self.firstFrame(url: cropped, width: Self.deliveredWidth,
                                                      height: Self.sourceHeight)
        let y = Self.sourceHeight / 2
        // Sample a few pixels inside the delivered frame, clear of the crop
        // boundary where halation can bleed across the removed band.
        for x in [2, 4, 6] {
            let delivered = Self.pixel(croppedPixels, width: Self.deliveredWidth, x: x, y: y)
            let centre = Self.pixel(widePixels, width: Self.sourceWidth,
                                    x: x + (Self.sourceWidth - Self.deliveredWidth) / 2, y: y)
            let removedBand = Self.pixel(widePixels, width: Self.sourceWidth, x: x / 2, y: y)
            let toCentre = Self.distance(delivered, centre)
            let toBand = Self.distance(delivered, removedBand)
            #expect(toCentre < toBand,
                    "x=\(x) delivered \(delivered) matched the removed band (\(toBand)) better than the centre (\(toCentre))")
        }
    }

    // MARK: - Fixture

    /// A 16:9 source with saturated red bands outside the 4:3 crop and green in
    /// the centre, so "which pixels survived" is measurable on the encoded file.
    /// The red bands are wider than the crop's removed 20 columns and stop
    /// short of the crop edge.
    private static func makeFixture(at url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sourceWidth,
            AVVideoHeightKey: sourceHeight
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sourceWidth,
                kCVPixelBufferHeightKey as String: sourceHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw FixtureError.writer(nil) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FixtureError.writer(nil) }
            fill(buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)) else {
                throw FixtureError.writer(writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.writer(writer.error) }
    }

    private static func fill(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<sourceHeight {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<sourceWidth {
                let removed = x < removedBandWidth || x >= sourceWidth - removedBandWidth
                row[x * 4 + 0] = 0                       // blue
                row[x * 4 + 1] = removed ? 0 : 220       // green in the kept centre
                row[x * 4 + 2] = removed ? 240 : 0       // red in the removed bands
                row[x * 4 + 3] = 255                     // alpha
            }
        }
    }

    // MARK: - Frame reading

    private static func firstFrame(url: URL, width: Int, height: Int) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let image = CMSampleBufferGetImageBuffer(sample) else {
            throw FixtureError.reader
        }
        #expect(CVPixelBufferGetWidth(image) == width)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw FixtureError.reader }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * 4) { pixels[y * width * 4 + i] = row[i] }
        }
        reader.cancelReading()
        return pixels
    }

    /// BGRA channels.
    private static func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (Int, Int, Int) {
        let index = (y * width + x) * 4
        return (Int(pixels[index + 2]), Int(pixels[index + 1]), Int(pixels[index]))
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    // MARK: - Helpers

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func loadConfig() -> FilmStockConfig {
        let url = TestRepository.root.appendingPathComponent("App/Resources/stocks.json")
        guard let data = try? Data(contentsOf: url),
              let container = try? JSONDecoder().decode(StockContainer.self, from: data),
              let config = container.stocks.first(where: { $0.stockId == "kodak5219" }) else {
            fatalError("kodak5219 stock configuration is required for the framing render test")
        }
        return config
    }

    private enum FixtureError: Error {
        case writer(Error?)
        case reader
    }

    private struct StockContainer: Decodable { let stocks: [FilmStockConfig] }
}
