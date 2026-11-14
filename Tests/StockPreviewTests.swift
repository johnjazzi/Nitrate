import Foundation
import Testing

struct StockPreviewTests {
    /// The preview belongs to the one picker both detents draw. Compact it is
    /// absent; expanded it sits above the same control stack, at the live gauge
    /// and the resolved push/pull.
    @Test func thePickerShowsTheLivePlatePreviewAboveItsControls() throws {
        let picker = try String(contentsOf: TestRepository.url(for: "App/Modules/FilmStockLibrary/CompactStockPicker.swift"),
                                encoding: .utf8)
        #expect(picker.contains("StockSamplePreview(stock:"),
                "The expanded picker must show the plate preview, not only stock swatches.")
        #expect(!picker.contains("StockSamplePhoto("),
                "Graded stills were replaced by plates graded at display time.")
        let preview = try #require(picker.range(of: "private var preview: some View"))
        let stack = try #require(picker.range(of: "private var controlStack: some View"))
        #expect(preview.lowerBound < stack.lowerBound,
                "The preview is above the one control stack, never beside a second set of controls.")
        // Expanded seats the preview then the same stack; compact draws the
        // stack alone, so the preview cannot appear at the short detent.
        let expanded = try #require(picker.range(of: "private var expandedContent"))
        let body = String(picker[expanded.lowerBound...])
        let plate = try #require(body.range(of: "preview.frame(height: split.height)"))
        let controls = try #require(body.range(of: "controlStack"))
        #expect(plate.lowerBound < controls.lowerBound)
        let compactStart = try #require(picker.range(of: "private var compactContent")).lowerBound
        let compactEnd = try #require(picker.range(of: "/// Expanded: the selected stock's sample")).lowerBound
        let compact = String(picker[compactStart..<compactEnd])
        #expect(!compact.contains("preview"),
                "The compact height shows no sample preview at all.")
        // The values are the render's: the selected stock's own gauge and the
        // exposure the sheet resolved from the live meter.
        #expect(picker.contains("gauge: gauge") && picker.contains("pushPullStops: resolvedPushPull.stops.stops"),
                "The preview must read the live gauge and the resolved push/pull.")
        #expect(!picker.contains("pushPullStops: manualStops"),
                "The preview must not read the stored rung directly: Auto resolves against the meter.")
    }

    @Test func thePreviewAppliesTheStocksCubeRatherThanAShippedGrade() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/Modules/FilmStockLibrary/StockSamplePreview.swift"),
                                encoding: .utf8)
        #expect(source.contains("platePreviewFragment"),
                "The preview must apply the cube on the GPU so a user LUT needs no new asset.")
        #expect(source.contains("stock?.lutName"),
                "The preview must use the selected stock's own cube.")
        #expect(!source.contains("StockSamplePhoto.load"),
                "No baked per-stock still should remain in the preview path.")
    }

    @Test func thePreviewShowsTheSelectedGaugesGrain() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/Modules/FilmStockLibrary/StockSamplePreview.swift"),
                                encoding: .utf8)
        #expect(source.contains("GrainModel.effectiveSize"),
                "Grain size must come from the renderer's own model, not a second guess.")
        #expect(source.contains("grain3d"),
                "The preview must sample the shipped grain volume.")
        let shader = try String(contentsOf: TestRepository.url(for: "Resources/Shaders/camera-preview.metal"),
                                encoding: .utf8)
        #expect(shader.contains("grainVolume.sample"),
                "The plate fragment must apply grain so the gauge is visible.")
    }
}
