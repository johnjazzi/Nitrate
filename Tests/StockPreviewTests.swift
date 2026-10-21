import Foundation
import Testing

struct StockPreviewTests {
    @Test func stockPickerShowsTheLivePlatePreviewAboveTheCarousel() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        let body = String(source[sheet.lowerBound...])
        #expect(body.contains("StockSamplePreview(stock:"),
                "The stock picker must show the plate preview, not only stock swatches.")
        #expect(!body.contains("StockSamplePhoto("),
                "Graded stills were replaced by plates graded at display time.")
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
}
