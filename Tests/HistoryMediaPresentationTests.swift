import Foundation
import Testing

/// Media-type classification for the compact History contact sheet.
///
/// A video poster is a JPEG too, so the receipt image must never decide whether
/// a cell gets the video frame-strip or the photo action tile. `isPhoto` is the
/// later explicit flag; legacy jobs are classified from their delivered codec,
/// output extension or source extension.
@Suite("History media classification")
struct HistoryMediaClassificationTests {
    private func job(_ filename: String, codec: String? = nil,
                     isPhoto: Bool? = nil, output: String? = nil) -> RenderJob {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/\(filename)"),
                            stockId: "kodak5219", iso: 500)
        job.isPhoto = isPhoto
        if let output { job.outputURL = URL(fileURLWithPath: "/tmp/\(output)") }
        job.receipt = RenderReceipt(codec: codec)
        return job
    }

    @Test func legacyDNGWithoutThePhotoFlagIsStillAPhoto() {
        let raw = job("capture.dng", codec: "com.adobe.raw-image")
        #expect(raw.isPhoto == nil)
        #expect(raw.presentsAsPhoto)
        #expect(job("capture.dng").presentsAsPhoto, "The source extension is enough for old entries")
        #expect(job("capture.cr3").presentsAsPhoto)
    }

    @Test func stillCodecClassifiesEvenWithAMovieSourceName() {
        #expect(job("legacy-take.mov", codec: "public.jpeg").presentsAsPhoto)
        #expect(job("legacy-take.mov", codec: "public.heic").presentsAsPhoto)
        #expect(job("legacy-take.mov", codec: "COM.ADOBE.RAW-IMAGE").presentsAsPhoto)
    }

    @Test func photoOutputExtensionClassifiesAReceiptWithoutACodec() {
        #expect(job("take.mov", output: "render.JPG").presentsAsPhoto)
        #expect(job("take.mov", output: "render.heic").presentsAsPhoto)
    }

    @Test func explicitPhotoFlagWinsForAnUnexpectedSourceName() {
        #expect(job("take.mov", isPhoto: true).presentsAsPhoto)
        #expect(!job("capture.dng", isPhoto: false).presentsAsPhoto,
                "The explicit flag describes the delivered job, not just its source")
    }

    /// The regression that matters: every video receipt carries a JPEG poster,
    /// and that must not turn a rendered movie into a photo cell.
    @Test func videoWithAJPEGThumbnailRemainsVideo() {
        var video = job("take.mov", codec: "hvc1")
        video.receipt?.thumbnailJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(!video.presentsAsPhoto)
        #expect(!job("take.mov", codec: "avc1", output: "render.mov").presentsAsPhoto)
    }

    @Test func legacyMovieWithoutAFlagOrImageEvidenceStaysVideo() {
        #expect(!job("take.mov").presentsAsPhoto)
        #expect(!job("take.MOV", codec: "hvc1").presentsAsPhoto)
    }

    /// Source contract: the accessor is the only display classifier and it never
    /// consults the receipt image, which the app cannot use as a type signal.
    @Test func classificationNeverReadsThePosterData() throws {
        let source = try String(contentsOf: TestRepository.root
            .appendingPathComponent("App/Modules/RenderQueue/RenderJob.swift"), encoding: .utf8)
        #expect(source.contains("Never infer type from thumbnailJPEG"))
        #expect(source.contains("if let codec = receipt?.codec?.lowercased(), imageCodecs.contains(codec) { return true }"))
        let start = try #require(source.range(of: "var presentsAsPhoto: Bool {"))
        let end = try #require(source.range(of: "var photoCropZoom: Double?"))
        let accessor = String(source[start.lowerBound..<end.lowerBound])
        #expect(!accessor.contains("thumbnailJPEG"))
    }
}
