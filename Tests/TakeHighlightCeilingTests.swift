import AVFoundation
import CoreVideo
import Foundation
import Testing

/// The take's highlight ceiling is MEASURED from the source, not assumed, and it
/// is the anchor of the push/pull hold. A wrong number there fails quietly: the
/// render still succeeds, it just drags blown highlights into the stock's cast,
/// which is the reported bug. So the sampling path is exercised against a real
/// movie — the reader settings, the 64RGBAHalf decode contract, the per-pixel
/// peak, and the percentile.
///
/// What this pins is that the number TRACKS the take. Which code a source byte
/// lands on is AVFoundation's business and not this test's subject, so the
/// assertions compare takes rather than hard-coding a decode.
@Suite(.serialized)
struct TakeHighlightCeilingTests {
    private static let side = 64
    private static let frames = 12

    private enum Failure: Error {
        case start(Error?)
    }

    /// A real take with a controlled bright patch: the right half of every frame
    /// is `bright`, the left half `background`.
    private func writeTake(bright: UInt8, background: UInt8, at url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422LT,
            AVVideoWidthKey: Self.side,
            AVVideoHeightKey: Self.side
        ])
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.side,
            kCVPixelBufferHeightKey as String: Self.side,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                          sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw Failure.start(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Self.frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.start(writer.error) }
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
                  let pixelBuffer = created else { throw Failure.start(writer.error) }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for row in 0..<Self.side {
                    let bytes = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                    for column in 0..<Self.side {
                        let value = column >= Self.side / 2 ? bright : background
                        bytes[column * 4] = value
                        bytes[column * 4 + 1] = value
                        bytes[column * 4 + 2] = value
                        bytes[column * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: Int64(index), timescale: 60)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw Failure.start(writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.start(writer.error) }
    }

    private func ceiling(of url: URL) async throws -> Float? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        let track = try #require(tracks.first)
        return await PipelineRenderer.measureHighlightCeiling(
            asset: asset, track: track, range: CMTimeRange(start: .zero, duration: duration))
    }

    /// One take at a time, in its own directory, removed afterwards.
    private func withTake<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory.appendingPathComponent("take.mov"))
    }

    private func measuredCeiling(bright: UInt8) async throws -> Float {
        try await withTake { url in
            try await writeTake(bright: bright, background: 32, at: url)
            let value = try await ceiling(of: url)
            return try #require(value, "a sampled take must report a ceiling")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func measuredCeilingTracksTheTakeHighlight() async throws {
        let dim = try await measuredCeiling(bright: 96)
        let bright = try await measuredCeiling(bright: 224)
        // The whole point: a brighter take reports a HIGHER ceiling, so the hold
        // moves with the scene instead of sitting at a constant.
        #expect(bright > dim, "dim=\(dim) bright=\(bright)")
        // And both sit inside the format: never negative, never below the white
        // floor, never past Apple Log 2's clip.
        for value in [dim, bright] {
            #expect(value >= 1 && value <= Float(PushPullTransfer.clipWhite),
                    "ceiling \(value) outside the recording range")
        }
    }

    /// A take that cannot be read reports nothing, so the render falls back to
    /// the authored ceiling instead of holding on a guess. A degenerate range is
    /// the cheap stand-in for an unreadable source.
    @Test(.timeLimit(.minutes(1)))
    func unreadableRangeReportsNoCeiling() async throws {
        try await withTake { url in
            try await writeTake(bright: 224, background: 32, at: url)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            let empty = await PipelineRenderer.measureHighlightCeiling(
                asset: asset, track: track,
                range: CMTimeRange(start: .zero, duration: .zero))
            #expect(empty == nil)
        }
    }
}
