import Foundation
import Testing

/// An imported raw is not a capture.
///
/// `PhotoCapturePolicy.maximumPixelCount` (12.19 MP) exists to size the DNGs THIS
/// app writes. It was also being applied to every import with `scaleFactor = 1`,
/// so a 16 MP Sony NEX-6 ARW, a 33 MP A7 IV or a 45 MP NEF was refused before it
/// could decode — a DSLR raw simply could not be developed.
///
/// The import budget is now its own number. These assertions are deliberately
/// about the NUMBERS rather than a decode: the failure they prevent is a future
/// edit quietly re-coupling the two budgets.
@Suite(.serialized)
struct RawImportBudgetTests {
    @Test func theImportBudgetAdmitsEveryStillInCirculation() {
        // Native sizes of raws actually measured on this project, plus the
        // heaviest current still cameras.
        let sentinel: [(String, Int)] = [
            ("Sony NEX-6 (16 MP)", 16_032_768),
            ("Nikon D700 (12 MP)", 12_212_224),
            ("Canon R5 (45 MP)", 47_000_000),
            ("Nikon Z8 (46 MP)", 45_720_000),
            ("Sony A7R V (61 MP)", 62_437_376),
        ]
        for (name, pixels) in sentinel {
            #expect(pixels <= RAWPhotoDecoder.maximumImportPixels,
                    "\(name) must open, not be refused")
        }
    }

    @Test func theImportBudgetIsNotTheCaptureBudget() {
        #expect(RAWPhotoDecoder.maximumImportPixels > PhotoCapturePolicy.maximumPixelCount,
                "a capture budget applied to imports is what refused every DSLR raw")
        // A capture is still bounded by the capture policy; only imports use the
        // wider number.
        #expect(PhotoCapturePolicy.maximumPixelCount == 12_192_768)
    }
}
