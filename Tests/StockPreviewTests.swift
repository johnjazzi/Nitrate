import Foundation
import Testing

struct StockPreviewTests {
    @Test func stockPickerExposesThePhotoPreviewAboveTheCarousel() throws {
        let source = try String(contentsOf: TestRepository.url(for: "App/ContentView.swift"), encoding: .utf8)
        let sheet = try #require(source.range(of: "private struct StockSheetView"))
        let body = String(source[sheet.lowerBound...])
        #expect(body.contains("StockSamplePreview(stock: localSelection)"),
                "The stock picker must expose real sample previews, not only stock swatches.")
    }
}
