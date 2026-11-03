import Foundation
import Testing

/// The metadata cards must state what the delivered file states: the resolved
/// push/pull, the real capture values, and honest blanks where a medium has no
/// such property.
struct MetadataCardsTests {
    private func job(photo: Bool = false,
                     metadata: [String: String] = [:],
                     pushPull: PushPullExposure? = nil) -> RenderJob {
        var job = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/take"),
                            stockId: "kodak5219", iso: 500,
                            printGauge: .thirtyFiveMillimetre, pushPull: pushPull)
        job.isPhoto = photo
        job.receipt = RenderReceipt(
            pixelWidth: 1080, pixelHeight: 1920, framesPerSecond: 23.98, codec: "hvc1",
            fileSizeBytes: 7_528_448, metadata: metadata,
            original: RenderReceipt.Original(codec: "hvc1", pixelWidth: 2160, pixelHeight: 3840,
                                             framesPerSecond: 23.98, fileSizeBytes: 38_154_240)
        )
        return job
    }

    private func cell(_ cards: [MetadataCard], _ label: String) -> MetadataCell? {
        cards.flatMap(\.rows).flatMap(\.cells).first { $0.label == label }
    }

    @Test func videoCardsStateProxyOriginalAndTheDeliveredPull() {
        let cards = ReceiptMetadataCards.make(job: job(metadata: [
            "com.filmemulation.push-pull-stops": "-2",
            "com.filmemulation.shutter-angle": "180",
            "com.filmemulation.iso": "500",
            "com.filmemulation.white-balance-kelvin": "5600",
            "com.filmemulation.wb-tint": "0",
            "com.filmemulation.color-space": "Apple Log 2",
            "com.filmemulation.reel": "1",
            "com.filmemulation.scene": "1",
            "com.filmemulation.take": "1"
        ]))

        // The notes card was removed: the metadata sheet carries no free-text field.
        #expect(cards.map(\.id) == ["file", "exposure", "color", "lens"])
        #expect(cell(cards, "Proxy")?.value == "H.265")
        #expect(cell(cards, "Frame Rate")?.value == "23.98")
        #expect(cell(cards, "Resolution")?.value == "1080 x 1920")
        #expect(cell(cards, "File Size")?.value == "7.18 MB")
        #expect(cell(cards, "Original Video")?.value == "H.265")
        #expect(cell(cards, "Shutter")?.value == "180°")
        #expect(cell(cards, "Iris")?.value == ReceiptMetadataCards.missing)
        #expect(cell(cards, "WB")?.value == "5600")
        #expect(cell(cards, "Color Space")?.value == "Apple Log 2")
        #expect(cell(cards, "Take")?.value == "1")
        // The file's resolved value wins over the job's stored preference.
        #expect(cell(cards, "Push / Pull")?.value == "PULL -2")
    }

    @Test func neutralRenderReadsZeroRatherThanAWord() {
        let cards = ReceiptMetadataCards.make(job: job(metadata: [
            "com.filmemulation.push-pull-stops": "0"
        ]))
        #expect(cell(cards, "Push / Pull")?.value == "0")
    }

    @Test func photoCardsUseTheStillsOwnLabelsAndNoFrameRate() {
        let cards = ReceiptMetadataCards.make(job: job(photo: true, metadata: [
            "com.filmemulation.shutter-speed": "1/500",
            "com.filmemulation.aperture-f-number": "3.99932",
            "com.filmemulation.lens": "iPhone 16 Pro back camera",
            "com.filmemulation.focal-length-mm": "24.0",
            "com.filmemulation.push-pull-stops": "1"
        ]))
        #expect(cell(cards, "Delivered")?.value == "H.265")
        #expect(cell(cards, "Original RAW")?.value == "H.265")
        #expect(cell(cards, "Frame Rate")?.value == ReceiptMetadataCards.missing)
        #expect(cell(cards, "Shutter")?.value == "1/500")
        #expect(cell(cards, "Iris")?.value == "f/3.99932")
        #expect(cell(cards, "Lens Data")?.value == "iPhone 16 Pro back camera 24mm")
        #expect(cell(cards, "Push / Pull")?.value == "PUSH +1")
    }

    /// The delivered file states the diffusion it rendered with, and the card
    /// repeats it rather than reading today's catalog.
    @Test func diffusionReadsTheDeliveredPresetAndAmount() {
        let cards = ReceiptMetadataCards.make(job: job(metadata: [
            "com.filmemulation.diffusion-preset": "radius35",
            "com.filmemulation.diffusion-amount": "0.4"
        ]))
        #expect(cell(cards, "Diffusion")?.value == "35px · 0.40")
    }

    /// Bypassed, silent and unrecorded are three different states and must not
    /// collapse into one another: 75 renders nothing by design, amount 0 renders
    /// nothing by choice, and a legacy file simply never said.
    @Test func bypassedSilentAndUnrecordedDiffusionStayDistinct() {
        let bypassed = ReceiptMetadataCards.make(job: job(metadata: [
            "com.filmemulation.diffusion-preset": "radius75",
            "com.filmemulation.diffusion-amount": "0.5"
        ]))
        #expect(cell(bypassed, "Diffusion")?.value == "Off")

        let silent = ReceiptMetadataCards.make(job: job(metadata: [
            "com.filmemulation.diffusion-preset": "radius8",
            "com.filmemulation.diffusion-amount": "0"
        ]))
        #expect(cell(silent, "Diffusion")?.value == "Off")

        let legacy = ReceiptMetadataCards.make(job: job(metadata: [:]))
        #expect(cell(legacy, "Diffusion")?.value == ReceiptMetadataCards.missing)

        // A job that has not delivered yet states what its gauge will render:
        // 16mm spreads 16 px at 0.30.
        var queued = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/take"), stockId: "kodak5219",
                               iso: 500, printGauge: .sixteenMillimetre)
        queued.receipt = nil
        #expect(cell(ReceiptMetadataCards.make(job: queued), "Diffusion")?.value == "16px · 0.30")

        // 75mm is bypassed no matter the amount.
        var bypassedJob = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/take"), stockId: "kodak5219",
                                    iso: 500, printGauge: .seventyFiveMillimetre)
        bypassedJob.receipt = nil
        #expect(cell(ReceiptMetadataCards.make(job: bypassedJob), "Diffusion")?.value == "Off")
    }

    @Test func missingEvidenceStaysBlank() {
        var empty = RenderJob(sourceURL: URL(fileURLWithPath: "/tmp/take"), stockId: "", iso: 0)
        empty.receipt = nil
        let cards = ReceiptMetadataCards.make(job: empty)
        #expect(cell(cards, "Proxy")?.value == ReceiptMetadataCards.missing)
        #expect(cell(cards, "Push / Pull")?.value == "0")
    }
}
