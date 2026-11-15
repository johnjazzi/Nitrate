import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("History first-frame preview")
struct QueueReceiptFirstFrameTests {
    @Test func readsTheFirstRenderedFrameWithinTheRequestedBound() async throws {
        // Generated 64×48 H.264 fixture: red first frame, blue second frame,
        // both keyframes. A second-frame request must fail the red assertion.
        let url = TestRepository.url(for: "Tests/Fixtures/history-first-frame.mov")
        let frame = try #require(await RenderReceiptService.firstFrame(at: url, maximumSize: 16))
        #expect(frame.width == 16)
        #expect(frame.height == 12)
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(Int(rgba[0]) > Int(rgba[2]) + 100, "Preview must use the red first frame, not the blue second frame")
    }

    @Test func missingAndNonlocalOutputsHaveNoPreview() async throws {
        let remote = try #require(URL(string: "https://example.invalid/not-local.mov"))
        let remoteFrame = await RenderReceiptService.firstFrame(at: remote)
        #expect(remoteFrame == nil)
        let missing = TestRepository.url(for: "Tests/Fixtures/missing-\(UUID().uuidString).mov")
        let missingFrame = await RenderReceiptService.firstFrame(at: missing)
        #expect(missingFrame == nil)
    }

    // MARK: - Grid poster decode bound

    /// A full retained-source receipt can carry a multi-megapixel poster. The
    /// contact sheet must decode display-sized pixels only.
    @Test func gridPosterDecodesWithinThe320PixelDisplayBound() throws {
        let jpeg = try sampleJPEG(width: 1200, height: 1600)
        let poster = try #require(RenderReceiptService.gridPoster(from: jpeg))
        #expect(poster.width > 0 && poster.height > 0)
        #expect(max(poster.width, poster.height) <= 320)
        #expect(abs(Double(poster.width) / Double(poster.height) - 0.75) < 0.02,
                "The poster keeps its portrait aspect; only the pixels are capped")
    }

    @Test func gridPosterBoundsTheLongEdgeOfALandscapeImage() throws {
        let jpeg = try sampleJPEG(width: 4000, height: 1000)
        let poster = try #require(RenderReceiptService.gridPoster(from: jpeg))
        #expect(poster.width == 320)
        #expect(poster.height == 80)
    }

    @Test func gridPosterRejectsNonImageBytes() {
        #expect(RenderReceiptService.gridPoster(from: Data()) == nil)
        #expect(RenderReceiptService.gridPoster(from: Data([0x00, 0x01, 0x02])) == nil)
        #expect(RenderReceiptService.gridPoster(from: Data("not a jpeg".utf8)) == nil)
    }

    private func sampleJPEG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.82, green: 0.24, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
