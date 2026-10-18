import AVFoundation
import CoreImage
import ImageIO
import Testing

@Suite("Private export receipts")
struct RenderExportReceiptTests {
    @Test func legacyJobDecodesWithoutInventedEvidenceAndReceiptRoundTrips() throws {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/external/old.mov"), stockId: "old", iso: 100)
        let data = try JSONEncoder().encode(job)
        let old = try JSONDecoder().decode(RenderJob.self, from: data)
        #expect(old.receipt == nil)
        #expect(old.mediaCleanupCompleted == nil)
        #expect(old.cleanupWarning == nil)
        job.receipt = RenderReceipt(durationSeconds: 1, pixelWidth: 90, pixelHeight: 160,
                                    framesPerSecond: 24, codec: "avc1", fileSizeBytes: 123,
                                    renderDurationSeconds: 0.2, thumbnailJPEG: Data([1, 2]),
                                    metadata: ["com.filmemulation.stock-name": "Test"], appVersion: "1", appBuild: "2")
        #expect(try JSONDecoder().decode(RenderJob.self, from: JSONEncoder().encode(job)) == job)
    }

    @Test func actualRotatedVideoProducesBoundedNonblankJPEGAndWhitelistedMetadata() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // Same AVAssetWriter/pixel-buffer fixture path as MovieWritingReliabilityTests,
        // with a deterministic two-tone frame instead of its uninitialized buffers.
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.metadata = [item("com.filmemulation.stock-name", "Test"),
                           item("com.filmemulation.location", "private"),
                           item("com.apple.quicktime.location.ISO6709", "+40-70/"),
                           item("com.filmemulation.unrecognized", "private")]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for index in 0..<12 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            let base = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
            let patch = CIImage(color: CIColor(red: 0.9, green: 0.7, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 360))
            context.render(patch.composited(over: base), to: pixels)
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let receipt = await RenderReceiptService.capture(url: url, renderDurationSeconds: 0.25)
        #expect(receipt.pixelWidth == 360)
        #expect(receipt.pixelHeight == 640)
        #expect(abs((receipt.framesPerSecond ?? 0) - 24) < 0.1)
        #expect((receipt.durationSeconds ?? 0) > 0)
        #expect((receipt.fileSizeBytes ?? 0) > 0)
        #expect(receipt.codec == "avc1")
        #expect(receipt.metadata == ["com.filmemulation.stock-name": "Test"])
        let jpeg = try #require(receipt.thumbnailJPEG)
        #expect(jpeg.count <= 64 * 1024)
        let imageSource = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(max(image.width, image.height) <= 320)
        #expect(image.height > image.width)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bitmap = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let red = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
        #expect(Int(red.max() ?? 0) - Int(red.min() ?? 0) > 80)
    }

    @Test func unreadablePosterStillReturnsMetadataPlaceholder() async {
        let receipt = await RenderReceiptService.capture(url: URL(fileURLWithPath: "/missing.mov"), renderDurationSeconds: nil)
        #expect(receipt.thumbnailJPEG == nil)
        #expect(receipt.durationSeconds == nil)
        #expect(receipt.renderDurationSeconds == nil)
    }

    private func item(_ key: String, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}
