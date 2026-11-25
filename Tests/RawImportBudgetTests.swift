import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing

/// An imported raw is admitted only if the develop can actually deliver it.
///
/// `PhotoCapturePolicy.maximumPixelCount` (12.19 MP) sizes the DNGs THIS app
/// writes. The decoder once used a separate 80 MP admission ceiling, so a
/// supported 24 MP raw could preview (the preview decodes at 960 px) and then
/// throw `Invalid still extent` in the production still stage. Comparing two
/// constants would not have caught that: the failure lived in the delivery
/// stage, so these assertions point at the rule that stage applies.
@Suite(.serialized)
struct RawImportBudgetTests {
    private final class BundleToken {}

    /// The qualified raster: 4032 x 3024, the geometry this app captures and
    /// develops end to end on hardware. One import path, one delivery stage.
    @Test func aFullResolutionPhoneStillPassesTheGateAndTheStillStage() {
        for (width, height) in [(4032, 3024), (3024, 4032)] {
            #expect(PhotoRenderBudget.accepts(width: width, height: height))
            #expect(PhotoImportService.sizeRefusal(width: width, height: height) == nil,
                    "\(width)x\(height) is the raster the app captures; it must import")
            #expect(StillFilmRenderResources.acceptsExtent(
                CGRect(x: 0, y: 0, width: width, height: height)),
                "the production still stage must accept the size the gate admitted")
        }
    }

    /// The 24 MP raw that previewed and then failed: refused before the copy,
    /// with the reason, and refused by the same rule the still stage applies.
    /// 24 MP is NOT supported by this change — no device measurement backs it.
    @Test func a24MegapixelImportIsRefusedUpFrontWithTheDeliveryReason() throws {
        let width = 6000, height = 4000
        #expect(!PhotoRenderBudget.accepts(width: width, height: height))
        #expect(!StillFilmRenderResources.acceptsExtent(
            CGRect(x: 0, y: 0, width: width, height: height)),
            "the still stage and the gate must never disagree about a size")

        let refusal = try #require(PhotoImportService.sizeRefusal(width: width, height: height))
        let message = try #require(refusal.errorDescription)
        #expect(message.contains("6000 × 4000"), "the refusal names the file's size")
        #expect(message.contains("24.0 MP"))
        #expect(message.contains("12.2 MP"), "and the size this device does develop")
        #expect(message.contains("tiled rendering"), "and why it cannot be delivered")

        // The decoder reports the same sentence, so a file that reaches it from
        // anywhere else cannot produce a different explanation.
        let decode = RAWPhotoDecoder.DecodeError.pixelBudget(width: width, height: height)
        #expect(decode.errorDescription == message)
    }

    /// Negative control: the refusal is a budget, not a blanket refusal.
    @Test func theGateRefusesOnlyWhatIsOverTheDeliveryBudget() {
        #expect(PhotoImportService.sizeRefusal(width: 1024, height: 768) == nil)
        #expect(PhotoImportService.sizeRefusal(width: 2016, height: 2688) == nil)
        // One row over the qualified raster is already over budget.
        #expect(PhotoImportService.sizeRefusal(width: 4033, height: 3024) != nil)
        // Degenerate dimensions are not a size refusal; the reader above reports
        // those as unreadable.
        #expect(PhotoImportService.sizeRefusal(width: 0, height: 0) == nil)
    }

    /// The camera's own capture ceiling is untouched; only the still delivery
    /// path has a budget, and it is the qualified raster, not the old admission
    /// ceiling.
    @Test func theCaptureBudgetIsUnchangedAndTheDeliveryBudgetIsNotTheOldAdmissionCeiling() {
        #expect(PhotoCapturePolicy.maximumPixelCount == 12_192_768)
        #expect(PhotoRenderBudget.maximumDeliverablePixels == 4032 * 3024,
                "the delivery budget is the raster this app has qualified on device")
        #expect(PhotoRenderBudget.megapixels(PhotoRenderBudget.maximumDeliverablePixels) == "12.2 MP")
        #expect(PhotoRenderBudget.megapixels(6000 * 4000) == "24.0 MP")
    }

    /// The exact regression, at the delivery stage: a frame of the largest
    /// admitted size must render through the production still stage instead of
    /// throwing `Invalid still extent`. A 24 MP frame is covered by the refusal
    /// above; tiling it is a separate project.
    @Test func theLargestAdmittedFrameRendersThroughTheStillStage() throws {
        let width = 4032, height = 3024
        let film = try StillFilmRenderResources(stockID: "kodak5219", gauge: .sixteenMillimetre,
                                                seed: 42, bundle: Bundle(for: BundleToken.self))
        let frame = CIImage(color: CIColor(red: 0.18, green: 0.10, blue: 0.06))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let halated = try film.halation(RAWToLog2Stage.apply(frame), sceneLiftStops: 1)
        #expect(Int(halated.extent.width) == width)
        #expect(Int(halated.extent.height) == height)

        // And a frame one row over is refused by the stage with the same reason,
        // never the bare extent error.
        let oversized = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height + 1))
        do {
            _ = try film.halation(RAWToLog2Stage.apply(oversized), sceneLiftStops: 1)
            Issue.record("a frame over the delivery budget reached the GPU")
        } catch DevelopmentPhotoRenderer.RenderError.decode(let message) {
            #expect(message != "Invalid still extent",
                    "an oversized frame must carry the delivery reason, not a bare extent error")
            #expect(message.contains("tiled rendering"))
        }
    }
}
